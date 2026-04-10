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
$safetyMarginPct = 0.15        # swap this % before predicted disconnect (15%)
$emaAlpha = 0.3                # EMA weight: higher = more reactive to recent data
$minDataPoints = 3             # minimum disconnects before enabling prediction
$staleProbeThreshold = 10      # seconds — treat probe as down if Updated is older than this
$minStableInterval = 8         # seconds — intervals shorter than this are bounces (excluded from EMA)
$latencyWindowSize = 20        # sliding window size for degradation detection
$jitterThreshold = 50          # ms stddev — above this, link is "jittery"
$trendThreshold = 5            # ms/sample slope — positive slope = worsening latency
$degradationLookaheadPct = 0.30 # trigger early swap if within this % of predicted disconnect AND degraded

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
$emaInterval = $null
$predictivelySwapped = $false
$savedPredictDisconnectAt = $null
$primaryUpSince = Get-Date
$secondaryUpSince = Get-Date
$primaryDownSince = $null
$secondaryDownSince = $null
$scriptStartTime = Get-Date
$primaryWasHealthy = $false     # track primary unhealthy→healthy transitions for EMA interval
$previousTickHealthy = $false   # last tick's health state — used to detect healthy→unhealthy transitions for disconnect logging
$primaryHealthySince = $null    # when current healthy streak began (bounce filtering)
$latencyWindow = [System.Collections.Generic.List[double]]::new()  # sliding window for degradation detection
$lastSwapTime = [datetime]::MinValue
$swapCooldown = 10
$disconnectsSinceLastTrim = 0

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
if (-not (Test-Path $logFile)) {
    "Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded" | Out-File $logFile -Encoding UTF8
    Write-Host "Created log file: $logFile" -ForegroundColor DarkGray
} else {
    try {
        $existing = Import-Csv $logFile
    } catch {
        Write-Host "Warning: could not parse log file, starting fresh: $_" -ForegroundColor Yellow
        $existing = @()
    }
    if ($existing.Count -gt 0) {
        foreach ($row in $existing) {
            try {
                $interval = [double]$row.IntervalSeconds
                if ($interval -gt 0 -and $interval -ge $minStableInterval) {
                    $intervals.Add($interval)
                }
                $lastDisconnectTime = [datetime]$row.Timestamp
                $predictionBaseTime = $lastDisconnectTime
                $lastEma = $row.EMA_Seconds
                if ($lastEma -ne "" -and $null -ne $lastEma) {
                    $emaInterval = [double]$lastEma
                }
            } catch {
                Write-Host "Skipping malformed log row: $($row | Out-String)" -ForegroundColor Yellow
                continue
            }
        }
        # If every row was malformed, lastDisconnectTime stays null — same as empty log
        if ($null -ne $lastDisconnectTime) {
            $count = $intervals.Count
            $emaDisplay = if ($null -ne $emaInterval) { "$([math]::Round($emaInterval))s" } else { "(not set)" }
            Write-Host "Loaded $count previous disconnects. EMA: $emaDisplay" -ForegroundColor DarkGray
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
    } elseif ($null -ne $script:lastDisconnectTime) {
        # Fallback for the very first disconnect after startup before any healthy transition
        # has been observed.
        $interval = ($now - $script:lastDisconnectTime).TotalSeconds
    }

    $fed = $false
    if ($interval -gt 0) {
        if ($interval -ge $minStableInterval) {
            # Feed stable intervals into the prediction dataset and EMA
            $script:intervals.Add($interval)
            # Trim to keep only the most recent entries — older data is still in the log file
            if ($script:intervals.Count -gt $maxIntervals) {
                $script:intervals.RemoveRange(0, $script:intervals.Count - $maxIntervals)
            }
            if ($null -eq $script:emaInterval) {
                $script:emaInterval = $interval
            } else {
                $script:emaInterval = ($emaAlpha * $interval) + ((1 - $emaAlpha) * $script:emaInterval)
            }
            $fed = $true
        } else {
            Write-Host "  (bounce: ${interval}s < ${minStableInterval}s threshold, skipping EMA)" -ForegroundColor DarkGray
        }
    }

    $script:lastDisconnectTime = $now
    # Null out predictionBaseTime — primary is down now, not healthy. The main loop re-sets it
    # when primary next transitions to healthy, which disables prediction during the outage.
    $script:predictionBaseTime = $null

    $emaStr = if ($null -ne $script:emaInterval) { [math]::Round($script:emaInterval) } else { "" }
    $deg = Get-LinkDegradation
    "$($now.ToString('yyyy-MM-dd HH:mm:ss')),$primary,$([math]::Round($interval)),$emaStr,$($deg.Jitter),$($deg.Trend),$($deg.Degraded)" |
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
        Write-Host "  LOGGED | Count: $count | Avg: ${avg}s | Min: ${min}s | Max: ${max}s | EMA: $([math]::Round($script:emaInterval))s" -ForegroundColor DarkYellow
    }
}

function Get-PredictedDisconnectTime {
    if ($script:intervals.Count -lt $minDataPoints -or $null -eq $script:emaInterval -or $null -eq $script:predictionBaseTime) {
        return $null
    }
    return $script:predictionBaseTime.AddSeconds($script:emaInterval)
}

function Get-AdaptiveSafetyMargin {
    if ($script:intervals.Count -lt $minDataPoints) {
        return $safetyMarginPct
    }
    $mean = ($script:intervals | Measure-Object -Average).Average
    if ($mean -le 0) { return $safetyMarginPct }

    $sumSqDiff = 0
    foreach ($v in $script:intervals) {
        $sumSqDiff += ($v - $mean) * ($v - $mean)
    }
    $stddev = [math]::Sqrt($sumSqDiff / $script:intervals.Count)
    $cv = $stddev / $mean

    $margin = $safetyMarginPct * (1 + $cv)
    return [math]::Min($margin, 0.40)
}

function Get-PredictiveSwapTime {
    $predictedDisconnect = Get-PredictedDisconnectTime
    if ($null -eq $predictedDisconnect) { return $null }
    $adaptiveMargin = Get-AdaptiveSafetyMargin
    $margin = $script:emaInterval * $adaptiveMargin
    return $predictedDisconnect.AddSeconds(-$margin)
}

function Get-LinkDegradation {
    if ($script:latencyWindow.Count -lt 5) {
        return @{ Jitter = 0; Trend = 0; Degraded = $false }
    }
    $values = $script:latencyWindow.ToArray()
    $n = $values.Count
    $mean = ($values | Measure-Object -Average).Average

    # Jitter = standard deviation of recent latencies
    $sumSqDiff = 0
    foreach ($v in $values) { $sumSqDiff += ($v - $mean) * ($v - $mean) }
    $jitter = [math]::Sqrt($sumSqDiff / $n)

    # Trend = linear regression slope (x = sample index, y = latency)
    $sumX = 0; $sumY = 0; $sumXY = 0; $sumX2 = 0
    for ($i = 0; $i -lt $n; $i++) {
        $sumX += $i
        $sumY += $values[$i]
        $sumXY += $i * $values[$i]
        $sumX2 += $i * $i
    }
    $denom = ($n * $sumX2) - ($sumX * $sumX)
    $trend = if ($denom -ne 0) { (($n * $sumXY) - ($sumX * $sumY)) / $denom } else { 0 }

    $degraded = ($jitter -gt $jitterThreshold) -or ($trend -gt $trendThreshold)
    return @{ Jitter = [math]::Round($jitter, 1); Trend = [math]::Round($trend, 2); Degraded = $degraded }
}

# --- Startup ---
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  WiFi Failover Watchdog + Prediction" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Primary:     $primary"
Write-Host "Secondary:   $secondary"
Write-Host "Ping mode:   ping.exe -S (async background threads)"
Write-Host "Threshold:   ${latencyThreshold}ms | Failover: $failoverThreshold | Recovery: $recoveryThreshold"
Write-Host "EMA alpha:   $emaAlpha | Safety margin: $($safetyMarginPct * 100)% base (adaptive)"
Write-Host "Bounce:      ${minStableInterval}s min stable | Jitter: ${jitterThreshold}ms | Trend: ${trendThreshold}ms/tick"
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
        }
        if (-not $pResult.Up) {
            $latencyWindow.Clear()
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
        # Bounce filter: only log if primary was stably healthy (>= minStableInterval).
        # Must run before $primaryHealthySince is cleared below.
        if ($previousTickHealthy -and -not $primaryHealthy) {
            if ($null -ne $primaryHealthySince -and
                ($now - $primaryHealthySince).TotalSeconds -ge $minStableInterval) {
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
                ($now - $primaryHealthySince).TotalSeconds -ge $minStableInterval) {
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
        $predictSwapAt = Get-PredictiveSwapTime
        $predictDisconnectAt = Get-PredictedDisconnectTime
        if ($null -ne $predictSwapAt) {
            $secsUntilSwap = [math]::Round(($predictSwapAt - $now).TotalSeconds)
            $marginPctDisplay = [math]::Round((Get-AdaptiveSafetyMargin) * 100)
            $predictStr = "Swap in ${secsUntilSwap}s (~$(Get-Date $predictSwapAt -Format 'HH:mm:ss')) margin=${marginPctDisplay}%"
        } else {
            $predictStr = "Learning"
        }

        Write-Host -NoNewline "[$ts] "
        Write-Host -NoNewline "P=$pTimeStr " -ForegroundColor $pColor
        Write-Host -NoNewline "S=$sTimeStr " -ForegroundColor $sColor
        Write-Host -NoNewline "Act=$activeAdapter " -ForegroundColor Cyan
        Write-Host -NoNewline "Total=${totalUptime}s " -ForegroundColor White
        Write-Host "[$predictStr]" -ForegroundColor DarkYellow

        # Show degradation warning when active on primary with enough data
        if ($activeAdapter -eq $primary -and $latencyWindow.Count -ge 5) {
            $deg = Get-LinkDegradation
            if ($deg.Degraded) {
                Write-Host "  [DEGRADED jitter=$($deg.Jitter)ms trend=$($deg.Trend)ms/tick]" -ForegroundColor Yellow
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
                    }
                }
            } else {
                $primaryFails = 0
            }

            # === DEGRADATION-TRIGGERED EARLY SWAP ===
            # If link quality is deteriorating and we're approaching a predicted disconnect, swap early
            if (-not $predictivelySwapped -and $null -ne $predictDisconnectAt -and $activeAdapter -eq $primary) {
                $degradation = Get-LinkDegradation
                if ($degradation.Degraded) {
                    $earlyWindow = $script:emaInterval * $degradationLookaheadPct
                    $earlySwapAt = $predictDisconnectAt.AddSeconds(-$earlyWindow)
                    if ($now -ge $earlySwapAt -and $earlySwapAt -ge $scriptStartTime -and $sResult.Up -and $sResult.Latency -le $latencyThreshold) {
                        $secsUntilDisconnect = [math]::Round(($predictDisconnectAt - $now).TotalSeconds)
                        Write-Host "  DEGRADATION SWAP -> $secondary (jitter=$($degradation.Jitter)ms trend=$($degradation.Trend)ms/tick, disconnect in ~${secsUntilDisconnect}s)" -ForegroundColor Blue
                        $result = Switch-To $secondary "degradation detected"
                        if ($null -ne $result) {
                            $activeAdapter = $result
                            $predictivelySwapped = $true
                            $savedPredictDisconnectAt = $predictDisconnectAt
                            $latencyWindow.Clear()
                        }
                    }
                }
            }

            # === PREDICTIVE SWAP ===
            # Only act on predictions in the future — ignore stale windows from before startup
            if (-not $predictivelySwapped -and $null -ne $predictSwapAt -and $activeAdapter -eq $primary) {
                if ($now -ge $predictSwapAt -and $predictSwapAt -ge $scriptStartTime -and $sResult.Up -and $sResult.Latency -le $latencyThreshold) {
                    $secsUntilDisconnect = [math]::Round(($predictDisconnectAt - $now).TotalSeconds)
                    Write-Host "  PREDICTIVE SWAP -> $secondary (predicted disconnect in ~${secsUntilDisconnect}s)" -ForegroundColor Blue
                    $result = Switch-To $secondary "predictive"
                    if ($null -ne $result) {
                        $activeAdapter = $result
                        $predictivelySwapped = $true
                        $savedPredictDisconnectAt = $predictDisconnectAt
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
                        # Re-anchor prediction base so the stale window doesn't re-trigger
                        if ($predictivelySwapped) {
                            $script:predictionBaseTime = $now
                        }
                        $predictivelySwapped = $false
                    }
                }
            } else {
                $secondaryFails = 0
            }

            # Swap back to primary once it recovers (sustained good pings)
            if (-not $predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
                $primaryRecoveredCount++
                if ($primaryRecoveredCount -ge $recoveryThreshold) {
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

            # Predictive return - wait past the disconnect window then return
            if ($predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
                $waitTime = $emaInterval * (Get-AdaptiveSafetyMargin) * 2
                $returnAfter = $savedPredictDisconnectAt.AddSeconds($waitTime)
                if ($now -gt $returnAfter) {
                    # Print explanation before Switch-To so message ordering is logical.
                    # If Switch-To returns $null (cooldown), the message still shows — this is
                    # informative as it indicates a return was attempted but suppressed.
                    Write-Host "  PREDICTIVE RETURN -> $primary (disconnect window passed)" -ForegroundColor Blue
                    $result = Switch-To $primary "predictive return"
                    if ($null -ne $result) {
                        if ($null -eq $script:predictionBaseTime) {
                            # A disconnect was logged during the window (Write-DisconnectLog
                            # nulls predictionBaseTime). Reset uptime anchor.
                            $primaryUpSince = $now
                        } else {
                            # False positive — primary stayed healthy the whole window.
                            $observedInterval = ($now - $script:predictionBaseTime).TotalSeconds
                            if ($null -ne $script:emaInterval -and $observedInterval -gt $script:emaInterval) {
                                $script:emaInterval = ($emaAlpha * $observedInterval) + ((1 - $emaAlpha) * $script:emaInterval)
                                Write-Host "  (false positive, EMA nudged to $([math]::Round($script:emaInterval))s)" -ForegroundColor DarkGray
                            } else {
                                Write-Host "  (no disconnect observed, skipping log)" -ForegroundColor DarkGray
                            }
                            # Leave $primaryUpSince alone so the display reflects real uptime.
                        }
                        # Re-anchor prediction base so next window is in the future
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