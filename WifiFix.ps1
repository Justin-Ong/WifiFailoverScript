# WiFi Failover Watchdog with Predictive Swapping
# Run as Administrator: Right-click PowerShell > Run as Administrator

# --- Configuration ---
$primary = "Wi-Fi 2"           # MediaTek
$secondary = "Wi-Fi 3"         # Realtek
$pingTarget = "192.168.50.1"
$checkInterval = 0.5           # seconds between display/decision ticks
$pingInterval = 0.5            # seconds between pings per adapter
$latencyThreshold = 200        # ms - above this is "degraded"
$failoverThreshold = 1         # consecutive failures before switching away
$recoveryThreshold = 10        # consecutive good pings before switching back
$goodMetric = 10
$badMetric = 500
$logFile = "$PSScriptRoot\disconnect_log.csv"
$maxLogLines = 500             # cap log file size
$maxIntervals = 500            # cap in-memory interval list
$swapProbThreshold = 0.65      # swap when this fraction of historical disconnects would have already occurred
$returnHoldPctile = 0.90       # stay on secondary until elapsed time exceeds this percentile of intervals
$maxHoldTime = 180             # hard ceiling on secondary hold time (seconds)
$degradationProbThreshold = 0.40 # lower swap threshold when link degradation is detected
$predictionWindowSize = 20     # number of recent intervals to use for CDF (0 = use all)
$minDataPoints = 3             # minimum disconnects before enabling prediction
$staleProbeThreshold = 10      # seconds — treat probe as down if Updated is older than this
$minStableIntervalFloor = 8    # absolute minimum — adaptive threshold won't go below this
$latencyWindowSize = 20        # sliding window size for degradation detection
$baselineWindowSize = 100      # sliding window size for long-term baseline
$jitterMultiplier = 2.5        # flag degradation when current jitter exceeds baseline * this
$minJitterThreshold = 15       # ms — absolute floor for jitter threshold (prevents triggering on noise when baseline is very low)
$trendThreshold = 5            # ms/sample slope — positive slope = worsening latency
$clusterGapThreshold = 120     # seconds — disconnects closer than this are part of the same cluster
$clusterHoldMultiplier = 2.0   # multiply return hold time when in a cluster
$clusterCooldownInterval = 300 # seconds — after a cluster ends, wait this long before trusting primary fully

# --- Validate environment ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  Right-click PowerShell and choose 'Run as Administrator'." -ForegroundColor Yellow
    exit 1
}

foreach ($name in @($primary, $secondary)) {
    try {
        $null = Get-NetAdapter -Name $name -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Adapter '$name' not found." -ForegroundColor Red
        Write-Host "Available adapters:" -ForegroundColor Yellow
        Get-NetAdapter | Format-Table Name, Status, InterfaceDescription -AutoSize | Out-Host
        exit 1
    }
}

# --- State ---
$primaryFails = 0
$secondaryFails = 0
$primaryRecoveredCount = 0
$activeAdapter = $primary
$lastDisconnectTime = $null
$predictionBaseTime = $null     # when to base next prediction from (may differ from lastDisconnectTime after false positives)
$intervals = [System.Collections.Generic.List[double]]::new()
$predictivelySwapped = $false
$primaryUpSince = Get-Date
$secondaryUpSince = Get-Date
$primaryDownSince = $null
$secondaryDownSince = $null
$scriptStartTime = Get-Date
$primaryWasHealthy = $false     # track primary unhealthy→healthy transitions for EMA interval
$previousTickHealthy = $false   # last tick's health state — used to detect healthy→unhealthy transitions for disconnect logging
$primaryHealthySince = $null    # when current healthy streak began (bounce filtering)
$latencyWindow = [System.Collections.Generic.List[double]]::new()  # sliding window for degradation detection
$baselineLatencyWindow = [System.Collections.Generic.List[double]]::new()  # long-term baseline for relative degradation
$lastSwapTime = [datetime]::MinValue
$swapCooldown = 10
$disconnectsSinceLastTrim = 0
$inCluster = $false
$clusterDisconnects = 0
$lastClusterEnd = $null         # when the last cluster was considered over

# --- Shared state for background ping threads ---
# Each state holds a single .Value containing an immutable snapshot object.
# Reference assignment is atomic in .NET, so the reader always gets a consistent snapshot
# without needing explicit locks.
$primaryState = [hashtable]::Synchronized(@{
    Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
})
$secondaryState = [hashtable]::Synchronized(@{
    Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
})

# --- Initialize log file ---
$newHeader = "Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster"
if (-not (Test-Path $logFile)) {
    $newHeader | Out-File $logFile -Encoding UTF8
    Write-Host "Created log file: $logFile" -ForegroundColor DarkGray
} else {
    # Migrate old CSV header if needed (EMA_Seconds -> Prob, add Cluster column)
    $firstLine = (Get-Content $logFile -TotalCount 1)
    if ($null -ne $firstLine -and $firstLine -match 'EMA_Seconds') {
        $allLines = Get-Content $logFile
        $allLines[0] = $newHeader
        $allLines | Set-Content $logFile -Encoding UTF8
        Write-Host "Migrated CSV header to new format" -ForegroundColor DarkGray
    }
    $lines = Get-Content $logFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' }
    if ($null -ne $lines -and $lines.Count -gt 1) {
        foreach ($line in ($lines | Select-Object -Skip 1)) {
            try {
                $parts = $line -split ','
                if ($parts.Count -lt 7) { continue }
                $interval = [double]$parts[2]
                if ($interval -gt 0 -and $interval -ge $minStableIntervalFloor) {
                    $intervals.Add($interval)
                }
                $lastDisconnectTime = [datetime]$parts[0]
                # NOTE: Do NOT set $predictionBaseTime here — let the main loop set it
                # when primary is actually observed healthy.
            } catch {
                Write-Host "Skipping malformed log row: $line" -ForegroundColor Yellow
                continue
            }
        }
        if ($null -ne $lastDisconnectTime) {
            $count = $intervals.Count
            Write-Host "Loaded $count previous disconnect intervals." -ForegroundColor DarkGray
        } else {
            Write-Host "Warning: no valid rows found in log, starting fresh" -ForegroundColor Yellow
        }
    }
}

# --- Background ping runspaces ---
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
$runspacePool.Open()

$pingLoopScript = {
    param($adapterName, $target, $intervalSec, $state)
    # Route through -Milliseconds so fractional $pingInterval values (e.g. 0.5) work;
    # PowerShell 5.1's -Seconds parameter is Int32 and would truncate.
    $intervalMs = [int]($intervalSec * 1000)
    while ($true) {
        try {
            $adapter = Get-NetAdapter -Name $adapterName -ErrorAction Stop
            if ($adapter.Status -ne "Up") {
                $state.Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
                Start-Sleep -Milliseconds $intervalMs; continue
            }
            $ifIndex = $adapter.ifIndex
            # Select-Object -First 1 — ping.exe -S expects a single source IP
            $ip = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress
            if ($null -eq $ip) {
                $state.Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
                Start-Sleep -Milliseconds $intervalMs; continue
            }
            $output = & ping.exe -S $ip -n 1 -w 2000 $target 2>&1
            $pingExit = $LASTEXITCODE
            if ($pingExit -eq 0) {
                # Exit code is locale-independent. Extract latency with a pattern that
                # doesn't depend on the "time=" word (which is localized on non-English Windows);
                # only "ms" is stable across locales.
                $joined = $output -join "`n"
                if ($joined -match '[=<](\d+)\s*ms') {
                    $state.Value = [PSCustomObject]@{ Up = $true; Latency = [int]$Matches[1]; Updated = Get-Date }
                } else {
                    # Ping succeeded but latency couldn't be parsed — treat as healthy with 0ms
                    # rather than a false negative.
                    $state.Value = [PSCustomObject]@{ Up = $true; Latency = 0; Updated = Get-Date }
                }
            } else {
                $state.Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
            }
        } catch {
            $state.Value = [PSCustomObject]@{ Up = $false; Latency = 9999; Updated = Get-Date }
        }
        Start-Sleep -Milliseconds $intervalMs
    }
}

# Capture launch timestamp so the startup readiness poll below can detect
# when a probe has actually written a post-launch snapshot.
$probeLaunchTime = Get-Date

$psPrimary = [PowerShell]::Create().AddScript($pingLoopScript)
$psPrimary.AddArgument($primary).AddArgument($pingTarget).AddArgument($pingInterval).AddArgument($primaryState) | Out-Null
$psPrimary.RunspacePool = $runspacePool
$handlePrimary = $psPrimary.BeginInvoke()

$psSecondary = [PowerShell]::Create().AddScript($pingLoopScript)
$psSecondary.AddArgument($secondary).AddArgument($pingTarget).AddArgument($pingInterval).AddArgument($secondaryState) | Out-Null
$psSecondary.RunspacePool = $runspacePool
$handleSecondary = $psSecondary.BeginInvoke()

function Set-AdapterPriority($adapterName, $metric) {
    try {
        $ifIndex = (Get-NetAdapter -Name $adapterName -ErrorAction Stop).ifIndex
        Set-NetIPInterface -InterfaceIndex $ifIndex -InterfaceMetric $metric -ErrorAction Stop
        return $true
    } catch {
        Write-Host "  Failed to set metric for $adapterName : $_" -ForegroundColor Red
        return $false
    }
}

function Switch-To($adapterName, $reason, [switch]$Force) {
    $now = Get-Date
    # Critical failovers (reactive/emergency) pass -Force to bypass the cooldown; optimizations
    # like predictive swap / predictive return keep the cooldown as a dampener.
    if (-not $Force -and ($now - $script:lastSwapTime).TotalSeconds -lt $swapCooldown) {
        Write-Host "  Swap to $adapterName suppressed (cooldown)" -ForegroundColor DarkGray
        return $null
    }
    if ($adapterName -eq $primary) {
        $ok1 = Set-AdapterPriority $primary $goodMetric
        $ok2 = Set-AdapterPriority $secondary $badMetric
    } else {
        $ok1 = Set-AdapterPriority $secondary $goodMetric
        $ok2 = Set-AdapterPriority $primary $badMetric
    }
    if (-not ($ok1 -and $ok2)) {
        Write-Host "  Swap to $adapterName FAILED (metric change error)" -ForegroundColor Red
        return $null
    }
    # Only advance the cooldown after a successful swap — a failed swap shouldn't burn
    # the retry window while the system is still on the bad adapter.
    $script:lastSwapTime = $now
    Write-Host ">>> ACTIVE: $adapterName ($reason) <<<" -ForegroundColor Green
    return $adapterName
}

function Write-DisconnectLog($disconnectTime = $null) {
    $now = if ($null -ne $disconnectTime) { $disconnectTime } else { Get-Date }
    $interval = 0

    # Interval = how long primary was actually healthy before this failure, NOT wall-clock
    # gap between logged disconnects. $predictionBaseTime is set whenever primary transitions
    # from unhealthy→healthy while it is the active adapter, so this measures primary's own
    # uptime cadence and excludes time spent on secondary.
    if ($null -ne $script:predictionBaseTime) {
        $interval = ($now - $script:predictionBaseTime).TotalSeconds
    } elseif ($null -ne $script:lastDisconnectTime -and $script:lastDisconnectTime -ge $script:scriptStartTime) {
        # Fallback for the very first disconnect after startup before any healthy transition
        # has been observed. Age guard: ignore if base timestamp predates script start.
        $interval = ($now - $script:lastDisconnectTime).TotalSeconds
    }

    $fed = $false
    $currentMinStable = Get-MinStableInterval
    if ($interval -gt 0) {
        if ($interval -ge $currentMinStable) {
            # Feed stable intervals into the prediction dataset
            $script:intervals.Add($interval)
            # Trim to keep only the most recent entries — older data is still in the log file
            if ($script:intervals.Count -gt $maxIntervals) {
                $script:intervals.RemoveRange(0, $script:intervals.Count - $maxIntervals)
            }
            $fed = $true
        } else {
            Write-Host "  (bounce: ${interval}s < ${currentMinStable}s threshold, skipping)" -ForegroundColor DarkGray
        }
    }

    # Update cluster detection state
    if ($interval -gt 0) {
        Update-ClusterState $interval
    }

    $script:lastDisconnectTime = $now
    # Null out predictionBaseTime — primary is down now, not healthy. The main loop re-sets it
    # when primary next transitions to healthy, which disables prediction during the outage.
    $script:predictionBaseTime = $null

    $prob = if ($interval -gt 0) { [math]::Round((Get-DisconnectProbability $interval), 2) } else { "" }
    $deg = Get-LinkDegradation
    "$($now.ToString('yyyy-MM-dd HH:mm:ss')),$primary,$([math]::Round($interval)),$prob,$($deg.Jitter),$($deg.Trend),$($deg.Degraded),$($script:inCluster)" |
        Out-File $logFile -Append -Encoding UTF8

    $script:disconnectsSinceLastTrim++
    if ($script:disconnectsSinceLastTrim -ge 50) {
        $lines = Get-Content $logFile
        if ($lines.Count -gt ($maxLogLines + 1)) {
            $lines[0..0] + $lines[($lines.Count - $maxLogLines)..($lines.Count - 1)] |
                Set-Content $logFile -Encoding UTF8
        }
        $script:disconnectsSinceLastTrim = 0
    }

    if ($fed) {
        $count = $script:intervals.Count
        $avg = [math]::Round(($script:intervals | Measure-Object -Average).Average)
        $min = [math]::Round(($script:intervals | Measure-Object -Minimum).Minimum)
        $max = [math]::Round(($script:intervals | Measure-Object -Maximum).Maximum)
        Write-Host "  LOGGED | Count: $count | Avg: ${avg}s | Min: ${min}s | Max: ${max}s" -ForegroundColor DarkYellow
    }
}

# --- Shared helper functions (also used by tests) ---
. "$PSScriptRoot\WifiFix-Functions.ps1"

# --- Startup ---
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  WiFi Failover Watchdog + Prediction" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Primary:     $primary"
Write-Host "Secondary:   $secondary"
Write-Host "Ping mode:   ping.exe -S (async background threads)"
Write-Host "Threshold:   ${latencyThreshold}ms | Failover: $failoverThreshold | Recovery: $recoveryThreshold"
Write-Host "Prediction:  CDF swap=$($swapProbThreshold * 100)% return=P$($returnHoldPctile * 100) maxhold=${maxHoldTime}s"
Write-Host "Bounce:      ${minStableIntervalFloor}s min stable (adaptive) | Jitter: ${jitterMultiplier}x baseline (floor ${minJitterThreshold}ms) | Trend: ${trendThreshold}ms/tick"
Write-Host "Cluster:     ${clusterGapThreshold}s gap | ${clusterHoldMultiplier}x hold | ${clusterCooldownInterval}s cooldown"
Write-Host "Min data:    $minDataPoints disconnects before prediction"
Write-Host "Max log:     $maxLogLines entries | Max intervals: $maxIntervals"
Write-Host "Log file:    $logFile"
Write-Host "Press Ctrl+C to stop"
Write-Host "==========================================="

$activeAdapter = Switch-To $primary "startup" -Force
if ($null -eq $activeAdapter) {
    Write-Host "ERROR: Failed to set initial adapter metrics. Aborting." -ForegroundColor Red
    exit 1
}

# Wait for background probes to populate real state before entering the main loop.
# Poll .Updated until both probes have written a post-launch timestamp, with a 5s
# fallback for slow systems. Replaces a fixed 2s sleep that was a timing guess.
$readyDeadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $readyDeadline) {
    if ($primaryState.Value.Updated -gt $probeLaunchTime -and
        $secondaryState.Value.Updated -gt $probeLaunchTime) { break }
    Start-Sleep -Milliseconds 100
}

# --- Main loop ---
try {
    while ($true) {
        $ts = Get-Date -Format "HH:mm:ss"
        $now = Get-Date

        # Atomic snapshot reads — each .Value is replaced as a whole by the background thread
        $pSnap = $primaryState.Value
        $sSnap = $secondaryState.Value
        # Staleness guard: if the probe thread stalled, the Updated timestamp will fall behind.
        # Treat a stale snapshot as down so we don't make decisions on frozen data.
        if (($now - $pSnap.Updated).TotalSeconds -gt $staleProbeThreshold) {
            $pResult = @{ Up = $false; Latency = 9999 }
        } else {
            $pResult = @{ Up = $pSnap.Up; Latency = $pSnap.Latency }
        }
        if (($now - $sSnap.Updated).TotalSeconds -gt $staleProbeThreshold) {
            $sResult = @{ Up = $false; Latency = 9999 }
        } else {
            $sResult = @{ Up = $sSnap.Up; Latency = $sSnap.Latency }
        }

        # --- Accumulate primary latency into sliding window for degradation detection ---
        if ($pResult.Up -and $pResult.Latency -lt 9999) {
            $latencyWindow.Add([double]$pResult.Latency)
            if ($latencyWindow.Count -gt $latencyWindowSize) {
                $latencyWindow.RemoveAt(0)
            }
            # Long-term baseline for relative degradation thresholds
            $baselineLatencyWindow.Add([double]$pResult.Latency)
            if ($baselineLatencyWindow.Count -gt $baselineWindowSize) {
                $baselineLatencyWindow.RemoveAt(0)
            }
        }
        if (-not $pResult.Up) {
            $latencyWindow.Clear()
            # NOTE: Do NOT clear $baselineLatencyWindow — baseline persists across brief outages
        }

        # --- Track up/down transitions for display ---
        if (-not $pResult.Up) {
            if ($null -eq $primaryDownSince) { $primaryDownSince = $now }
        } else {
            if ($null -ne $primaryDownSince) { $primaryUpSince = $now }
            $primaryDownSince = $null
        }
        if (-not $sResult.Up) {
            if ($null -eq $secondaryDownSince) { $secondaryDownSince = $now }
        } else {
            if ($null -ne $secondaryDownSince) { $secondaryUpSince = $now }
            $secondaryDownSince = $null
        }

        # --- Track primary health state continuously (even while on secondary) ---
        # The healthy-streak timer runs regardless of active adapter so that when we
        # failback, the bounce debounce is already satisfied if primary was stable.
        $primaryHealthy = $pResult.Up -and $pResult.Latency -le $latencyThreshold
        if ($primaryHealthy -and -not $primaryWasHealthy) {
            $primaryHealthySince = $now
        }

        # --- Centralized disconnect detection ---
        # Log a disconnect the moment primary transitions from healthy to unhealthy,
        # regardless of which adapter is active or which swap path brought us here.
        # Bounce filter: only log if primary was stably healthy (>= adaptive min stable).
        # Must run before $primaryHealthySince is cleared below.
        if ($previousTickHealthy -and -not $primaryHealthy) {
            if ($null -ne $primaryHealthySince -and
                ($now - $primaryHealthySince).TotalSeconds -ge (Get-MinStableInterval)) {
                Write-DisconnectLog $now
            }
        }
        $previousTickHealthy = $primaryHealthy

        if (-not $primaryHealthy) {
            $primaryHealthySince = $null
        }
        $primaryWasHealthy = $primaryHealthy

        # Only anchor prediction base while primary is the active adapter — secondary-active
        # periods are excluded from the "primary uptime before failure" measurement.
        if ($activeAdapter -eq $primary) {
            if ($primaryHealthy -and $null -ne $primaryHealthySince -and $null -eq $predictionBaseTime -and
                ($now - $primaryHealthySince).TotalSeconds -ge (Get-MinStableInterval)) {
                $predictionBaseTime = $now
            }
        }

        # --- Display ---
        if ($null -ne $primaryDownSince) {
            $pTimeStr = "DOWN($([math]::Round(($now - $primaryDownSince).TotalSeconds))s)"
            $pColor = "Red"
        } elseif ($pResult.Latency -gt $latencyThreshold) {
            $pTimeStr = "$($pResult.Latency)ms($([math]::Round(($now - $primaryUpSince).TotalSeconds))s)"
            $pColor = "Red"
        } else {
            $pTimeStr = "$($pResult.Latency)ms($([math]::Round(($now - $primaryUpSince).TotalSeconds))s)"
            $pColor = "Green"
        }

        if ($null -ne $secondaryDownSince) {
            $sTimeStr = "DOWN($([math]::Round(($now - $secondaryDownSince).TotalSeconds))s)"
            $sColor = "Red"
        } elseif ($sResult.Latency -gt $latencyThreshold) {
            $sTimeStr = "$($sResult.Latency)ms($([math]::Round(($now - $secondaryUpSince).TotalSeconds))s)"
            $sColor = "Red"
        } else {
            $sTimeStr = "$($sResult.Latency)ms($([math]::Round(($now - $secondaryUpSince).TotalSeconds))s)"
            $sColor = "Green"
        }

        $totalUptime = [math]::Round(($now - $scriptStartTime).TotalSeconds)
        if ($null -ne $predictionBaseTime -and $intervals.Count -ge $minDataPoints) {
            $elapsed = ($now - $predictionBaseTime).TotalSeconds
            $prob = Get-DisconnectProbability $elapsed
            $probPct = [math]::Round($prob * 100)
            $predictStr = "P=${probPct}% elapsed=$([math]::Round($elapsed))s"
        } else {
            $needed = $minDataPoints - $intervals.Count
            $predictStr = if ($needed -gt 0) { "Learning ($needed more)" } else { "Waiting" }
        }

        $clusterStr = ""
        if ($inCluster) {
            $clusterStr = " [CLUSTER x$clusterDisconnects]"
        } elseif ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
            $remaining = [math]::Round($clusterCooldownInterval - ($now - $lastClusterEnd).TotalSeconds)
            $clusterStr = " [POST-CLUSTER ${remaining}s]"
        }

        Write-Host -NoNewline "[$ts] "
        Write-Host -NoNewline "P=$pTimeStr " -ForegroundColor $pColor
        Write-Host -NoNewline "S=$sTimeStr " -ForegroundColor $sColor
        Write-Host -NoNewline "Act=$activeAdapter " -ForegroundColor Cyan
        Write-Host -NoNewline "Total=${totalUptime}s " -ForegroundColor White
        Write-Host "[$predictStr]$clusterStr" -ForegroundColor DarkYellow

        # Show degradation warning when active on primary with enough data
        if ($activeAdapter -eq $primary -and $latencyWindow.Count -ge 5) {
            $deg = Get-LinkDegradation
            if ($deg.Degraded) {
                Write-Host "  [DEGRADED jitter=$($deg.Jitter)ms(thr=$($deg.JitterThreshold)ms) trend=$($deg.Trend)ms/tick]" -ForegroundColor Yellow
            }
        }

        # === PRIMARY IS ACTIVE ===
        if ($activeAdapter -eq $primary) {
            $primaryRecoveredCount = 0

            if (-not $pResult.Up -or $pResult.Latency -gt $latencyThreshold) {
                $primaryFails++
                if ($primaryFails -ge $failoverThreshold -and $sResult.Up -and $sResult.Latency -le $latencyThreshold) {
                    Write-Host "  REACTIVE FAILOVER -> $secondary" -ForegroundColor Magenta
                    # -Force bypasses the swap cooldown — this is a critical failover, not an
                    # optimization.
                    $result = Switch-To $secondary "reactive failover" -Force
                    if ($null -ne $result) {
                        $activeAdapter = $result
                        $primaryFails = 0
                        $primaryRecoveredCount = 0
                        $predictivelySwapped = $false
                        $latencyWindow.Clear()
                    }
                }
            } else {
                $primaryFails = 0
            }

            # === PREDICTIVE SWAP (CDF-based) ===
            if (-not $predictivelySwapped -and $activeAdapter -eq $primary -and
                $null -ne $predictionBaseTime -and $intervals.Count -ge $minDataPoints) {
                $elapsed = ($now - $predictionBaseTime).TotalSeconds
                $prob = Get-DisconnectProbability $elapsed

                # Use a lower threshold if link degradation is detected
                $threshold = $swapProbThreshold
                $degradation = Get-LinkDegradation
                if ($degradation.Degraded) {
                    $threshold = $degradationProbThreshold
                }
                # Recently exited a cluster — lower threshold for earlier swap
                if ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
                    $threshold = [math]::Min($threshold, $degradationProbThreshold)
                }

                if ($prob -ge $threshold -and $sResult.Up -and $sResult.Latency -le $latencyThreshold) {
                    $probPct = [math]::Round($prob * 100)
                    $reason = if ($degradation.Degraded) { "predictive+degraded P=${probPct}%" } else { "predictive P=${probPct}%" }
                    Write-Host "  PREDICTIVE SWAP -> $secondary ($reason)" -ForegroundColor Blue
                    $result = Switch-To $secondary $reason
                    if ($null -ne $result) {
                        $activeAdapter = $result
                        $predictivelySwapped = $true
                        $latencyWindow.Clear()
                    }
                }
            }

        # === SECONDARY IS ACTIVE ===
        } else {
            $primaryFails = 0

            # Failover to primary if secondary degrades
            # Uses $failoverThreshold — this is failing *away* from a bad adapter
            if (-not $sResult.Up -or $sResult.Latency -gt $latencyThreshold) {
                $secondaryFails++
                if ($secondaryFails -ge $failoverThreshold -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
                    Write-Host "  FAILBACK -> $primary (secondary degraded)" -ForegroundColor Magenta
                    # Secondary just degraded while it was the active adapter — critical, bypass cooldown.
                    $result = Switch-To $primary "failback - secondary degraded" -Force
                    if ($null -ne $result) {
                        $activeAdapter = $result
                        $secondaryFails = 0
                        $primaryRecoveredCount = 0
                        $primaryUpSince = $now
                        # Let the main loop re-anchor predictionBaseTime after the
                        # bounce debounce is satisfied, rather than setting it here
                        # where primary may not have been healthy long enough.
                        $script:predictionBaseTime = $null
                        $predictivelySwapped = $false
                    }
                }
            } else {
                $secondaryFails = 0
            }

            # Swap back to primary once it recovers (sustained good pings)
            if (-not $predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
                $primaryRecoveredCount++
                # During a cluster or shortly after one, require more recovery evidence
                $effectiveThreshold = $recoveryThreshold
                if ($inCluster) {
                    $effectiveThreshold = $recoveryThreshold * $clusterHoldMultiplier
                } elseif ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
                    # Recently exited a cluster — use intermediate threshold
                    $effectiveThreshold = [math]::Ceiling($recoveryThreshold * 1.5)
                }
                if ($primaryRecoveredCount -ge $effectiveThreshold) {
                    Write-Host "  FAILBACK -> $primary (primary recovered)" -ForegroundColor Magenta
                    $result = Switch-To $primary "failback - primary recovered"
                    if ($null -ne $result) {
                        $activeAdapter = $result
                        $primaryUpSince = $now
                        $primaryRecoveredCount = 0
                        $secondaryFails = 0
                        $predictivelySwapped = $false
                    }
                }
            } else {
                $primaryRecoveredCount = 0
            }

            # === PREDICTIVE RETURN (CDF-based) ===
            if ($predictivelySwapped -and $null -ne $predictionBaseTime -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
                $elapsed = ($now - $predictionBaseTime).TotalSeconds
                $returnAfterInterval = Get-IntervalPercentile $returnHoldPctile

                # During a cluster, extend the hold time
                if ($inCluster -and $null -ne $returnAfterInterval) {
                    $returnAfterInterval = $returnAfterInterval * $clusterHoldMultiplier
                }

                $holdExpired = ($null -ne $returnAfterInterval -and $elapsed -gt $returnAfterInterval)
                $effectiveMaxHold = if ($inCluster) { $maxHoldTime * $clusterHoldMultiplier } else { $maxHoldTime }
                $hardTimeout = ($now - $lastSwapTime).TotalSeconds -gt $effectiveMaxHold

                if ($holdExpired -or $hardTimeout) {
                    $reason = if ($hardTimeout) { "max hold time" } else { "disconnect window passed" }
                    if ($inCluster) { $reason += " (cluster)" }
                    Write-Host "  PREDICTIVE RETURN -> $primary ($reason)" -ForegroundColor Blue
                    $result = Switch-To $primary "predictive return"
                    if ($null -ne $result) {
                        if ($null -eq $script:predictionBaseTime) {
                            # A disconnect was logged during the window (Write-DisconnectLog
                            # nulls predictionBaseTime). Reset uptime anchor.
                            $primaryUpSince = $now
                        }
                        # Re-anchor prediction base for next window
                        $script:predictionBaseTime = $now
                        $activeAdapter = $result
                        $primaryRecoveredCount = 0
                        $predictivelySwapped = $false
                    }
                }
            }
        }

        # -Milliseconds supports fractional $checkInterval values (e.g. 0.5) on PS 5.1
        Start-Sleep -Milliseconds ([int]($checkInterval * 1000))
    }
} finally {
    Write-Host "`nShutting down..." -ForegroundColor Yellow
    # Restore automatic metrics so route preferences aren't left altered after exit.
    # Without this, closing the watchdog while on the secondary leaves the primary with
    # the bad metric indefinitely.
    try {
        Set-NetIPInterface -InterfaceAlias $primary -AutomaticMetric Enabled -ErrorAction Stop
        Set-NetIPInterface -InterfaceAlias $secondary -AutomaticMetric Enabled -ErrorAction Stop
        Write-Host "  Restored automatic metrics on $primary and $secondary" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Warning: failed to restore metrics: $_" -ForegroundColor Yellow
    }
    try { $psPrimary.Stop() } catch { }
    try { $psPrimary.EndInvoke($handlePrimary) } catch { }
    try { $psPrimary.Dispose() } catch { }
    try { $psSecondary.Stop() } catch { }
    try { $psSecondary.EndInvoke($handleSecondary) } catch { }
    try { $psSecondary.Dispose() } catch { }
    try { $runspacePool.Close() } catch { }
    try { $runspacePool.Dispose() } catch { }
    Write-Host "Cleanup complete." -ForegroundColor Green
}