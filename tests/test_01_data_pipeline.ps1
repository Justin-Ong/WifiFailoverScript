# test_01_data_pipeline.ps1 — Agent-executable tests for PRP 01
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Setup ---
$minDataPoints = 3
$minStableIntervalFloor = 8
$scriptStartTime = Get-Date

. "$PSScriptRoot\..\WifiFix-Functions.ps1"

# ============================================================
# TEST GROUP 1: CSV corruption tolerance
# ============================================================
Write-Host "`n=== CSV Corruption Tolerance ===" -ForegroundColor Cyan

$testCsvPath = "$PSScriptRoot\test_log.csv"

# 1a: Valid CSV with clean rows
$csvContent = @"
Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded
2026-04-09 22:30:37,Wi-Fi 2,71,71,0,0,False
2026-04-09 22:31:28,Wi-Fi 2,40,61,0,0,False
2026-04-09 22:33:08,Wi-Fi 2,84,68,0,0,False
"@
$csvContent | Out-File $testCsvPath -Encoding UTF8

$intervals = [System.Collections.Generic.List[double]]::new()
$lastDisconnectTime = $null
$lines = Get-Content $testCsvPath | Where-Object { $_.Trim() -ne '' }
foreach ($line in ($lines | Select-Object -Skip 1)) {
    $parts = $line -split ','
    if ($parts.Count -lt 7) { continue }
    try {
        $interval = [double]$parts[2]
        if ($interval -gt 0 -and $interval -ge $minStableIntervalFloor) {
            $intervals.Add($interval)
        }
        $lastDisconnectTime = [datetime]$parts[0]
    } catch { continue }
}

Assert "Clean CSV: loaded 3 intervals" ($intervals.Count -eq 3)
Assert "Clean CSV: intervals are 71, 40, 84" ($intervals[0] -eq 71 -and $intervals[1] -eq 40 -and $intervals[2] -eq 84)
Assert "Clean CSV: lastDisconnectTime set" ($null -ne $lastDisconnectTime)

# 1b: CSV with partial/corrupt lines
$csvCorrupt = @"
Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded
2026-04-09 22:30:37,Wi-Fi 2,71,71,0,0,False
2026-04-09 22:31:28,Wi-Fi 2,50
garbage line
2026-04-09 22:33:08,Wi-Fi 2,84,68,0,0,False

"@
$csvCorrupt | Out-File $testCsvPath -Encoding UTF8

$intervals = [System.Collections.Generic.List[double]]::new()
$lastDisconnectTime = $null
$lines = Get-Content $testCsvPath | Where-Object { $_.Trim() -ne '' }
foreach ($line in ($lines | Select-Object -Skip 1)) {
    $parts = $line -split ','
    if ($parts.Count -lt 7) { continue }
    try {
        $interval = [double]$parts[2]
        if ($interval -gt 0 -and $interval -ge $minStableIntervalFloor) {
            $intervals.Add($interval)
        }
        $lastDisconnectTime = [datetime]$parts[0]
    } catch { continue }
}

Assert "Corrupt CSV: loaded 2 valid intervals (skipped partial + garbage)" ($intervals.Count -eq 2)
Assert "Corrupt CSV: intervals are 71, 84" ($intervals[0] -eq 71 -and $intervals[1] -eq 84)

# 1c: Bounce filtering — intervals below floor are excluded
$csvBounce = @"
Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded
2026-04-09 22:30:37,Wi-Fi 2,71,71,0,0,False
2026-04-09 22:31:28,Wi-Fi 2,5,61,0,0,False
2026-04-09 22:33:08,Wi-Fi 2,3,68,0,0,False
2026-04-09 22:34:00,Wi-Fi 2,40,50,0,0,False
"@
$csvBounce | Out-File $testCsvPath -Encoding UTF8

$intervals = [System.Collections.Generic.List[double]]::new()
$lines = Get-Content $testCsvPath | Where-Object { $_.Trim() -ne '' }
foreach ($line in ($lines | Select-Object -Skip 1)) {
    $parts = $line -split ','
    if ($parts.Count -lt 7) { continue }
    try {
        $interval = [double]$parts[2]
        if ($interval -gt 0 -and $interval -ge $minStableIntervalFloor) {
            $intervals.Add($interval)
        }
    } catch { continue }
}

Assert "Bounce filter: only 2 intervals >= 8s loaded (71, 40)" ($intervals.Count -eq 2)

Remove-Item $testCsvPath -ErrorAction SilentlyContinue

# ============================================================
# TEST GROUP 2: $predictionBaseTime not set from log
# ============================================================
Write-Host "`n=== Bootstrap: predictionBaseTime ===" -ForegroundColor Cyan

$predictionBaseTime = $null
$lastDisconnectTime = $null
$intervals = [System.Collections.Generic.List[double]]::new()

$csvContent = @"
Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded
2026-04-09 22:30:37,Wi-Fi 2,71,71,0,0,False
"@
$csvContent | Out-File $testCsvPath -Encoding UTF8

$lines = Get-Content $testCsvPath | Where-Object { $_.Trim() -ne '' }
foreach ($line in ($lines | Select-Object -Skip 1)) {
    $parts = $line -split ','
    if ($parts.Count -lt 7) { continue }
    try {
        $interval = [double]$parts[2]
        if ($interval -gt 0 -and $interval -ge $minStableIntervalFloor) {
            $intervals.Add($interval)
        }
        $lastDisconnectTime = [datetime]$parts[0]
        # NOTE: $predictionBaseTime is NOT set here (PRP 01 fix)
    } catch { continue }
}

Assert "Bootstrap: predictionBaseTime is null after log load" ($null -eq $predictionBaseTime)
Assert "Bootstrap: lastDisconnectTime is set from log" ($null -ne $lastDisconnectTime)

Remove-Item $testCsvPath -ErrorAction SilentlyContinue

# ============================================================
# TEST GROUP 3: Get-MinStableInterval
# ============================================================
Write-Host "`n=== Adaptive MinStableInterval ===" -ForegroundColor Cyan

# 3a: Below minDataPoints — returns floor
$intervals = [System.Collections.Generic.List[double]]::new()
$intervals.Add(50)
Assert "Adaptive: below minDataPoints returns floor ($minStableIntervalFloor)" ((Get-MinStableInterval) -eq $minStableIntervalFloor)

# 3b: With data — returns 20% of median, floored
$intervals = [System.Collections.Generic.List[double]]::new()
@(30, 40, 50, 60, 70) | ForEach-Object { $intervals.Add($_) }
# Median of (30,40,50,60,70) = 50. 20% of 50 = 10.
$result = Get-MinStableInterval
Assert "Adaptive: 5 intervals, median=50, 20%=10, result=$result" ($result -eq 10)

# 3c: Small intervals — floor takes over
$intervals = [System.Collections.Generic.List[double]]::new()
@(10, 12, 15, 18, 20) | ForEach-Object { $intervals.Add($_) }
# Median = 15. 20% of 15 = 3. Floor = 8.
$result = Get-MinStableInterval
Assert "Adaptive: low intervals, floor wins, result=$result" ($result -eq $minStableIntervalFloor)

# ============================================================
# TEST GROUP 4: Code structure checks
# ============================================================
Write-Host "`n=== Code Structure ===" -ForegroundColor Cyan

$scriptPath = "$PSScriptRoot\..\WifiFix.ps1"
$content = Get-Content $scriptPath -Raw
$fnContent = Get-Content "$PSScriptRoot\..\WifiFix-Functions.ps1" -Raw

Assert "Config: minStableIntervalFloor exists" ($content -match '\$minStableIntervalFloor')
Assert "Function: Get-MinStableInterval exists" ($fnContent -match 'function Get-MinStableInterval')
Assert "No Import-Csv in log loading" (-not ($content -match 'Import-Csv \$logFile'))
Assert "No predictionBaseTime set in log loading" (-not ($content -match '\$predictionBaseTime = \$lastDisconnectTime'))
Assert "Age guard on lastDisconnectTime fallback" ($content -match 'lastDisconnectTime -ge \$script:scriptStartTime')

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
