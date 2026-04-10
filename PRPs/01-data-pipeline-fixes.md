# PRP 01: Data Pipeline Fixes

**Status: Completed**

## Goal

Fix three independent data quality issues that corrupt the prediction model's input. These must be completed before PRP 02 (prediction engine replacement) since the new model relies on the same `$intervals` list.

## Context

- Script: `WifiFix.ps1`
- Log file: `disconnect_log.csv` (CSV with header `Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded`)
- `$intervals` is a `[System.Collections.Generic.List[double]]` that stores historical disconnect intervals and feeds the prediction engine
- `Write-DisconnectLog` is the function that computes intervals, feeds them into `$intervals`, and appends to the CSV
- `$predictionBaseTime` marks when primary last became stably healthy; used as the anchor for interval measurement

## Tasks

### 1. Fix log bootstrap — stop pre-setting `$predictionBaseTime`

**File:** `WifiFix.ps1`, log loading section (around line 83–106)

**Problem:** On startup, the log loader sets `$predictionBaseTime = $lastDisconnectTime` from the CSV. If the last log entry was hours ago (overnight), this creates a stale prediction anchor. The main loop's `$scriptStartTime` guard partially protects against acting on it, but it also prevents the main loop from re-setting `$predictionBaseTime` on the first healthy transition because the variable is already non-null.

Additionally, `Write-DisconnectLog` has a fallback path:
```powershell
} elseif ($null -ne $script:lastDisconnectTime) {
    $interval = ($now - $script:lastDisconnectTime).TotalSeconds
}
```
Since `$lastDisconnectTime` is also loaded from the CSV, the first disconnect after a long gap would still produce a stale interval through this fallback.

**Changes:**

1. In the log loading `foreach` loop, **remove** the line:
   ```powershell
   $predictionBaseTime = $lastDisconnectTime
   ```
   `$predictionBaseTime` stays `$null` at startup and gets set by the main loop when primary is first observed stably healthy.

2. In `Write-DisconnectLog`, add an age guard to the `elseif` fallback. After computing `$interval` from `$lastDisconnectTime`, skip feeding it if the base timestamp predates `$scriptStartTime`:
   ```powershell
   } elseif ($null -ne $script:lastDisconnectTime -and $script:lastDisconnectTime -ge $script:scriptStartTime) {
       $interval = ($now - $script:lastDisconnectTime).TotalSeconds
   }
   ```

3. In the startup display, remove the EMA display line since PRP 02 will remove EMA entirely. For now, just change it to show interval count:
   ```powershell
   Write-Host "Loaded $count previous disconnect intervals." -ForegroundColor DarkGray
   ```

### 2. CSV corruption tolerance

**File:** `WifiFix.ps1`, log loading section (around line 83–106)

**Problem:** `Import-Csv` fails on partial/corrupt lines and the `catch` block discards the entire log. If the script is killed mid-write, all historical data is lost on next startup.

**Changes:**

Replace the `Import-Csv` block with manual line parsing:

```powershell
} else {
    $lines = Get-Content $logFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' }
    if ($null -ne $lines -and $lines.Count -gt 1) {
        foreach ($line in ($lines | Select-Object -Skip 1)) {
            try {
                $parts = $line -split ','
                if ($parts.Count -lt 7) { continue }
                $interval = [double]$parts[2]
                if ($interval -gt 0 -and $interval -ge $minStableInterval) {
                    $intervals.Add($interval)
                }
                $lastDisconnectTime = [datetime]$parts[0]
                # NOTE: Do NOT set $predictionBaseTime here (see Task 1)
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
```

Key differences from the original:
- No `Import-Csv` — splits each line manually
- Skips lines with fewer than 7 comma-separated fields (corrupt/partial)
- Silently skips individual bad lines instead of discarding everything
- Does not load `$emaInterval` from `EMA_Seconds` column (will be removed by PRP 02; ignore it for now)

### 3. Adaptive `$minStableInterval`

**File:** `WifiFix.ps1`, configuration section and `Write-DisconnectLog`

**Problem:** The fixed 8s threshold is too low. During disconnect bursts, primary recovers for 8–12s between drops and these short intervals drag the prediction model down.

**Changes:**

1. In the configuration section, rename `$minStableInterval` to `$minStableIntervalFloor` and keep the value:
   ```powershell
   $minStableIntervalFloor = 8   # absolute minimum — adaptive threshold won't go below this
   ```

2. Add a helper function after the existing function definitions:
   ```powershell
   function Get-MinStableInterval {
       if ($script:intervals.Count -lt $minDataPoints) {
           return $minStableIntervalFloor
       }
       # 20% of the median recent interval, floored at $minStableIntervalFloor
       $sorted = $script:intervals | Sort-Object
       $medianIdx = [math]::Floor($sorted.Count / 2)
       $median = $sorted[$medianIdx]
       return [math]::Max($minStableIntervalFloor, $median * 0.20)
   }
   ```

3. Replace all references to `$minStableInterval` with calls to `Get-MinStableInterval`:
   - In `Write-DisconnectLog`: the `if ($interval -ge $minStableInterval)` check
   - In the centralized disconnect detection block: the `($now - $primaryHealthySince).TotalSeconds -ge $minStableInterval` check
   - In the prediction base anchoring block: the `($now - $primaryHealthySince).TotalSeconds -ge $minStableInterval` check
   - In the log loading section (Task 2 above): the `$interval -ge $minStableInterval` filter — replace with `$minStableIntervalFloor` here since `Get-MinStableInterval` isn't meaningful during bootstrap

4. In the startup display, update the "Bounce" line to show the floor value:
   ```powershell
   Write-Host "Bounce:      ${minStableIntervalFloor}s min stable (adaptive) | ..."
   ```

## Verification

After completing all changes, create and run `tests\test_01_data_pipeline.ps1` with the following content. All assertions must pass.

```powershell
# test_01_data_pipeline.ps1 — Agent-executable tests for PRP 01
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Setup: extract functions and config from WifiFix.ps1 ---
# We source only the function/variable definitions, not the main loop.
# Build a minimal harness with the required variables.

$minDataPoints = 3
$minStableIntervalFloor = 8
$scriptStartTime = Get-Date

# Paste Get-MinStableInterval from WifiFix.ps1 here (after PRP 01 changes)
# The test expects this function to exist in the current scope.
# Copy it from WifiFix.ps1 after implementation.

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
Write-Host "`n=== Bootstrap: predictionBaseTime ==" -ForegroundColor Cyan

# Simulate the log loading block — predictionBaseTime must NOT be set
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
Assert "Adaptive: median=50, returns 10 (20% of 50)" ($result -eq 10)

# 3c: Small intervals — floor kicks in
$intervals = [System.Collections.Generic.List[double]]::new()
@(10, 15, 20) | ForEach-Object { $intervals.Add($_) }
# Median = 15. 20% of 15 = 3. Floor = 8.
$result = Get-MinStableInterval
Assert "Adaptive: median=15, floor wins -> returns $minStableIntervalFloor" ($result -eq $minStableIntervalFloor)

# ============================================================
# TEST GROUP 4: Stale lastDisconnectTime age guard
# ============================================================
Write-Host "`n=== Stale lastDisconnectTime Guard ===" -ForegroundColor Cyan

# Simulate Write-DisconnectLog's elseif fallback
$scriptStartTime = Get-Date
$predictionBaseTime = $null
$lastDisconnectTime = (Get-Date).AddHours(-8)  # 8 hours ago (from CSV)

# The guard: only use lastDisconnectTime if it's after scriptStartTime
$interval = 0
if ($null -ne $predictionBaseTime) {
    $interval = ((Get-Date) - $predictionBaseTime).TotalSeconds
} elseif ($null -ne $lastDisconnectTime -and $lastDisconnectTime -ge $scriptStartTime) {
    $interval = ((Get-Date) - $lastDisconnectTime).TotalSeconds
}

Assert "Stale guard: interval is 0 when lastDisconnectTime predates scriptStartTime" ($interval -eq 0)

# Now set a recent lastDisconnectTime
$lastDisconnectTime = (Get-Date).AddSeconds(-30)
$interval = 0
if ($null -ne $predictionBaseTime) {
    $interval = ((Get-Date) - $predictionBaseTime).TotalSeconds
} elseif ($null -ne $lastDisconnectTime -and $lastDisconnectTime -ge $scriptStartTime) {
    $interval = ((Get-Date) - $lastDisconnectTime).TotalSeconds
}

Assert "Stale guard: interval is ~30s when lastDisconnectTime is recent" ($interval -ge 29 -and $interval -le 32)

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
```

**Instructions for the agent:**
1. Complete all implementation tasks in this PRP first.
2. Copy the `Get-MinStableInterval` function from the modified `WifiFix.ps1` into the marked location in the test script.
3. Create the test file at `tests\test_01_data_pipeline.ps1`.
4. Run it: `powershell -File tests\test_01_data_pipeline.ps1`
5. All assertions must pass. Fix any failures before marking this PRP complete.

### Manual verification (cannot be automated)

1. **Stale bootstrap end-to-end:** Run the full script, log 3+ disconnects, stop, wait 5+ minutes, restart. Confirm `$predictionBaseTime` is set by the main loop (not from log) on first healthy observation.

## Dependencies

- None (this is the first PRP)
- PRP 02 depends on this being completed first
