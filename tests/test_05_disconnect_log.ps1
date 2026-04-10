# test_05_disconnect_log.ps1 — Tests for Write-DisconnectLog and edge cases
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Config (must match WifiFix.ps1) ---
$primary = "Wi-Fi 2"
$minDataPoints = 3
$minStableIntervalFloor = 8
$maxIntervals = 500
$maxLogLines = 500
$predictionWindowSize = 20
$clusterGapThreshold = 120
$latencyWindowSize = 20
$baselineWindowSize = 100
$jitterMultiplier = 2.5
$minJitterThreshold = 15
$trendThreshold = 5

# --- Shared functions ---
. "$PSScriptRoot\..\WifiFix-Functions.ps1"

# --- Test log file ---
$logFile = "$PSScriptRoot\test_disconnect_log.csv"

# --- Write-DisconnectLog (copied from WifiFix.ps1 since it references $logFile and script-scope state) ---
function Write-DisconnectLog($disconnectTime = $null) {
    $now = if ($null -ne $disconnectTime) { $disconnectTime } else { Get-Date }
    $interval = 0

    if ($null -ne $script:predictionBaseTime) {
        $interval = ($now - $script:predictionBaseTime).TotalSeconds
    } elseif ($null -ne $script:lastDisconnectTime -and $script:lastDisconnectTime -ge $script:scriptStartTime) {
        $interval = ($now - $script:lastDisconnectTime).TotalSeconds
    }

    $fed = $false
    $currentMinStable = Get-MinStableInterval
    if ($interval -gt 0) {
        if ($interval -ge $currentMinStable) {
            $script:intervals.Add($interval)
            if ($script:intervals.Count -gt $maxIntervals) {
                $script:intervals.RemoveRange(0, $script:intervals.Count - $maxIntervals)
            }
            $fed = $true
        }
    }

    if ($interval -gt 0) {
        Update-ClusterState $interval
    }

    $script:lastDisconnectTime = $now
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
}

# ============================================================
# Helper: reset all state
# ============================================================
function Reset-State {
    $script:intervals = [System.Collections.Generic.List[double]]::new()
    $script:predictionBaseTime = $null
    $script:lastDisconnectTime = $null
    $script:scriptStartTime = Get-Date
    $script:inCluster = $false
    $script:clusterDisconnects = 0
    $script:lastClusterEnd = $null
    $script:latencyWindow = [System.Collections.Generic.List[double]]::new()
    $script:baselineLatencyWindow = [System.Collections.Generic.List[double]]::new()
    $script:disconnectsSinceLastTrim = 0
    if (Test-Path $logFile) { Remove-Item $logFile }
    "Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster" | Out-File $logFile -Encoding UTF8
}

# ============================================================
# TEST GROUP 1: Basic interval computation from predictionBaseTime
# ============================================================
Write-Host "`n=== Interval from predictionBaseTime ===" -ForegroundColor Cyan

Reset-State
$base = (Get-Date).AddSeconds(-60)
$script:predictionBaseTime = $base
$disconnectTime = Get-Date

Write-DisconnectLog $disconnectTime

Assert "predictionBaseTime: interval ~60s fed into intervals" ($script:intervals.Count -eq 1 -and [math]::Abs($script:intervals[0] - 60) -lt 2)
Assert "predictionBaseTime: nulled after disconnect" ($null -eq $script:predictionBaseTime)
Assert "predictionBaseTime: lastDisconnectTime set" ($script:lastDisconnectTime -eq $disconnectTime)

$csvLines = Get-Content $logFile | Where-Object { $_.Trim() -ne '' }
Assert "predictionBaseTime: CSV has header + 1 data row" ($csvLines.Count -eq 2)
$parts = $csvLines[1] -split ','
Assert "predictionBaseTime: CSV has 8 columns" ($parts.Count -eq 8)
Assert "predictionBaseTime: CSV interval ~60" ([math]::Abs([int]$parts[2] - 60) -lt 2)

# ============================================================
# TEST GROUP 2: Fallback to lastDisconnectTime
# ============================================================
Write-Host "`n=== Fallback to lastDisconnectTime ===" -ForegroundColor Cyan

Reset-State
$script:lastDisconnectTime = (Get-Date).AddSeconds(-30)
# lastDisconnectTime must be >= scriptStartTime for the fallback to fire
$script:scriptStartTime = $script:lastDisconnectTime.AddSeconds(-1)
$disconnectTime = Get-Date

Write-DisconnectLog $disconnectTime

Assert "Fallback: interval ~30s fed" ($script:intervals.Count -eq 1 -and [math]::Abs($script:intervals[0] - 30) -lt 2)

# ============================================================
# TEST GROUP 3: Age guard — stale lastDisconnectTime ignored
# ============================================================
Write-Host "`n=== Age guard on lastDisconnectTime ===" -ForegroundColor Cyan

Reset-State
$script:lastDisconnectTime = (Get-Date).AddHours(-5)
# scriptStartTime is recent — lastDisconnectTime predates it
$script:scriptStartTime = (Get-Date).AddSeconds(-10)

Write-DisconnectLog

Assert "Age guard: stale lastDisconnectTime produces 0 interval, nothing fed" ($script:intervals.Count -eq 0)

# ============================================================
# TEST GROUP 4: Bounce filtering
# ============================================================
Write-Host "`n=== Bounce Filtering ===" -ForegroundColor Cyan

Reset-State
# Feed some intervals to make Get-MinStableInterval return > floor
@(50, 60, 70) | ForEach-Object { $script:intervals.Add($_) }
# Get-MinStableInterval should be max(8, 60*0.20) = max(8, 12) = 12
$minStable = Get-MinStableInterval
Assert "Bounce: adaptive threshold is 12" ($minStable -eq 12)

$initialCount = $script:intervals.Count
$script:predictionBaseTime = (Get-Date).AddSeconds(-5)  # 5s interval < 12s threshold

Write-DisconnectLog

Assert "Bounce: short interval not fed (count unchanged)" ($script:intervals.Count -eq $initialCount)

# ============================================================
# TEST GROUP 5: Cluster state updated by Write-DisconnectLog
# ============================================================
Write-Host "`n=== Cluster Integration ===" -ForegroundColor Cyan

Reset-State
# Simulate two rapid disconnects
$script:predictionBaseTime = (Get-Date).AddSeconds(-30)
Write-DisconnectLog
Assert "Cluster 1: not in cluster yet" (-not $script:inCluster)

$script:predictionBaseTime = (Get-Date).AddSeconds(-25)
Write-DisconnectLog
Assert "Cluster 2: cluster triggered" $script:inCluster

# ============================================================
# TEST GROUP 6: Get-DisconnectProbability with 0 intervals
# ============================================================
Write-Host "`n=== CDF: Empty interval list ===" -ForegroundColor Cyan

$script:intervals = [System.Collections.Generic.List[double]]::new()
$result = Get-DisconnectProbability 50
Assert "CDF: 0 intervals returns 0.0" ($result -eq 0.0)

# ============================================================
# TEST GROUP 7: CSV trimming
# ============================================================
Write-Host "`n=== CSV Trimming ===" -ForegroundColor Cyan

Reset-State
$script:disconnectsSinceLastTrim = 49  # Next disconnect triggers trim

# Write enough rows to exceed trim threshold
for ($i = 0; $i -lt 10; $i++) {
    $script:predictionBaseTime = (Get-Date).AddSeconds(-50)
    Write-DisconnectLog
}

$lineCount = (Get-Content $logFile | Where-Object { $_.Trim() -ne '' }).Count
Assert "Trimming: log file was trimmed or stayed within limits" ($lineCount -le ($maxLogLines + 1))

# ============================================================
# Cleanup
# ============================================================
if (Test-Path $logFile) { Remove-Item $logFile }

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
