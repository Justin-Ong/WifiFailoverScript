# PRP 02: Replace Prediction Engine with Hazard-Rate CDF

**Status: Completed**

## Goal

Replace the EMA-based point prediction system with an empirical CDF (cumulative distribution function) model. Instead of predicting a single disconnect time and adding a margin, the new model computes the probability that a disconnect has occurred given the elapsed uptime, and swaps when that probability exceeds a threshold.

## Prerequisites

- PRP 01 (data pipeline fixes) must be completed first. This PRP assumes:
  - `$predictionBaseTime` is no longer set during log bootstrap
  - CSV loading uses manual line parsing (not `Import-Csv`)
  - `$minStableInterval` is replaced by `Get-MinStableInterval` / `$minStableIntervalFloor`

## Context

- Script: `WifiFix.ps1`
- `$intervals` is a `[System.Collections.Generic.List[double]]` of historical disconnect intervals (seconds of primary uptime before each failure)
- `$predictionBaseTime` is set when primary becomes stably healthy while active; marks the start of the current uptime period
- The current prediction functions to replace: `Get-PredictedDisconnectTime`, `Get-AdaptiveSafetyMargin`, `Get-PredictiveSwapTime`

## New Configuration Parameters

Remove these parameters from the configuration section:
- `$safetyMarginPct = 0.15`
- `$emaAlpha = 0.3`
- `$degradationLookaheadPct = 0.30`

Add these parameters in their place:
```powershell
$swapProbThreshold = 0.65      # swap when this fraction of historical disconnects would have already occurred
$returnHoldPctile = 0.90       # stay on secondary until elapsed time exceeds this percentile of intervals
$maxHoldTime = 180             # hard ceiling on secondary hold time (seconds)
$degradationProbThreshold = 0.40 # lower swap threshold when link degradation is detected
$predictionWindowSize = 20     # number of recent intervals to use for CDF (0 = use all)
```

## Tasks

### 1. Remove EMA state variables

**File:** `WifiFix.ps1`, State section (around line 47–68)

Remove:
```powershell
$emaInterval = $null
$savedPredictDisconnectAt = $null
```

These are no longer used. `$predictivelySwapped` stays — still needed to track whether we're in a predictive swap window.

### 2. Add CDF function

**File:** `WifiFix.ps1`, after the existing function definitions (after `Get-LinkDegradation`)

Add:
```powershell
function Get-DisconnectProbability {
    param([double]$elapsedSeconds)
    if ($script:intervals.Count -lt $minDataPoints) { return 0.0 }
    # Use the most recent $predictionWindowSize intervals, or all if 0
    if ($predictionWindowSize -gt 0 -and $script:intervals.Count -gt $predictionWindowSize) {
        $window = $script:intervals.GetRange(
            $script:intervals.Count - $predictionWindowSize, $predictionWindowSize
        )
    } else {
        $window = $script:intervals
    }
    $count = 0
    foreach ($v in $window) {
        if ($v -le $elapsedSeconds) { $count++ }
    }
    return $count / $window.Count
}
```

Also add a helper to get a specific percentile from the intervals:
```powershell
function Get-IntervalPercentile {
    param([double]$percentile)
    if ($script:intervals.Count -lt $minDataPoints) { return $null }
    if ($predictionWindowSize -gt 0 -and $script:intervals.Count -gt $predictionWindowSize) {
        $window = $script:intervals.GetRange(
            $script:intervals.Count - $predictionWindowSize, $predictionWindowSize
        )
    } else {
        $window = $script:intervals
    }
    $sorted = $window | Sort-Object
    $idx = [math]::Min([math]::Floor($sorted.Count * $percentile), $sorted.Count - 1)
    return $sorted[$idx]
}
```

### 3. Remove old prediction functions

**File:** `WifiFix.ps1`

Delete these three functions entirely:
- `Get-PredictedDisconnectTime` (around line 280)
- `Get-AdaptiveSafetyMargin` (around line 287)
- `Get-PredictiveSwapTime` (around line 302)

### 4. Update `Write-DisconnectLog`

**File:** `WifiFix.ps1`, `Write-DisconnectLog` function

Changes:
1. Remove all EMA computation logic (the `$script:emaInterval` assignments).
2. Keep the interval calculation, `$intervals.Add()`, bounce filtering, and CSV appending.
3. Update the CSV line to write `Prob` instead of `EMA_Seconds`. Compute the probability at the moment of disconnect:
   ```powershell
   $prob = if ($interval -gt 0) { Get-DisconnectProbability $interval } else { "" }
   ```
   CSV format becomes: `Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded`
4. Update the summary `Write-Host` line to show probability instead of EMA:
   ```powershell
   Write-Host "  LOGGED | Count: $count | Avg: ${avg}s | Min: ${min}s | Max: ${max}s" -ForegroundColor DarkYellow
   ```

**Important:** Also update the CSV header written when creating a new log file (around line 78):
```powershell
"Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded" | Out-File $logFile -Encoding UTF8
```

**Backward compatibility:** The log loading code from PRP 01 reads `$parts[2]` (IntervalSeconds) by index. The column position doesn't change, so old logs with `EMA_Seconds` in position 3 will still load correctly — position 3 is simply ignored.

### 5. Replace predictive swap logic (primary active)

**File:** `WifiFix.ps1`, main loop, "PRIMARY IS ACTIVE" section

**Remove** the entire "DEGRADATION-TRIGGERED EARLY SWAP" block and the "PREDICTIVE SWAP" block. Replace both with a single unified block:

```powershell
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
```

Note: No `$scriptStartTime` guard is needed because `$predictionBaseTime` is only set by the main loop after startup (per PRP 01), so the prediction window is always current.

### 6. Replace predictive return logic (secondary active)

**File:** `WifiFix.ps1`, main loop, "SECONDARY IS ACTIVE" section

**Replace** the existing predictive return block with:

```powershell
# === PREDICTIVE RETURN (CDF-based) ===
if ($predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
    $elapsed = ($now - $predictionBaseTime).TotalSeconds
    $returnAfterInterval = Get-IntervalPercentile $returnHoldPctile
    $holdExpired = ($null -ne $returnAfterInterval -and $elapsed -gt $returnAfterInterval)
    $hardTimeout = ($now - $lastSwapTime).TotalSeconds -gt $maxHoldTime

    if ($holdExpired -or $hardTimeout) {
        $reason = if ($hardTimeout) { "max hold time" } else { "disconnect window passed" }
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
```

Key differences from original:
- No `$savedPredictDisconnectAt` — uses `$predictionBaseTime` + percentile directly
- No false-positive EMA nudge — CDF self-corrects as new longer intervals enter the dataset
- Hard timeout (`$maxHoldTime`) prevents being stuck on secondary indefinitely if the interval distribution shifts dramatically

### 7. Update secondary-degraded failback

**File:** `WifiFix.ps1`, main loop, secondary-degraded block

In the existing secondary-degraded failback, remove this line:
```powershell
if ($predictivelySwapped) {
    $script:predictionBaseTime = $now
}
```

Replace with just:
```powershell
$script:predictionBaseTime = $now
```

The re-anchoring should happen unconditionally on any failback to primary, not just during predictive windows. This ensures the next CDF check starts from the right baseline.

### 8. Update display line

**File:** `WifiFix.ps1`, main loop, display section

Replace the prediction countdown display logic. Find:
```powershell
$predictSwapAt = Get-PredictiveSwapTime
$predictDisconnectAt = Get-PredictedDisconnectTime
if ($null -ne $predictSwapAt) {
    $secsUntilSwap = [math]::Round(($predictSwapAt - $now).TotalSeconds)
    $marginPctDisplay = [math]::Round((Get-AdaptiveSafetyMargin) * 100)
    $predictStr = "Swap in ${secsUntilSwap}s (~$(Get-Date $predictSwapAt -Format 'HH:mm:ss')) margin=${marginPctDisplay}%"
} else {
    $predictStr = "Learning"
}
```

Replace with:
```powershell
if ($null -ne $predictionBaseTime -and $intervals.Count -ge $minDataPoints) {
    $elapsed = ($now - $predictionBaseTime).TotalSeconds
    $prob = Get-DisconnectProbability $elapsed
    $probPct = [math]::Round($prob * 100)
    $predictStr = "P=${probPct}% elapsed=$([math]::Round($elapsed))s"
} else {
    $needed = $minDataPoints - $intervals.Count
    $predictStr = if ($needed -gt 0) { "Learning ($needed more)" } else { "Waiting" }
}
```

Also remove the `$predictDisconnectAt` variable reference from the degradation display block (around line 500) since it no longer exists. The degradation warning display stays as-is.

### 9. Update startup banner

**File:** `WifiFix.ps1`, startup section

Replace:
```powershell
Write-Host "EMA alpha:   $emaAlpha | Safety margin: $($safetyMarginPct * 100)% base (adaptive)"
```

With:
```powershell
Write-Host "Prediction:  CDF swap=${swapProbThreshold * 100}% return=P$($returnHoldPctile * 100) maxhold=${maxHoldTime}s"
```

Remove `$degradationLookaheadPct` from the display if it appears.

### 10. Clean up dead references

Search the entire file for any remaining references to these removed variables/functions and delete or replace them:
- `$emaInterval`
- `$emaAlpha`
- `$safetyMarginPct`
- `$savedPredictDisconnectAt`
- `$degradationLookaheadPct`
- `Get-PredictedDisconnectTime`
- `Get-AdaptiveSafetyMargin`
- `Get-PredictiveSwapTime`

## Verification

After completing all changes, create and run `tests\test_02_cdf_engine.ps1` with the following content. All assertions must pass.

```powershell
# test_02_cdf_engine.ps1 — Agent-executable tests for PRP 02
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Config (must match WifiFix.ps1) ---
$minDataPoints = 3
$predictionWindowSize = 20
$swapProbThreshold = 0.65
$returnHoldPctile = 0.90
$maxHoldTime = 180
$degradationProbThreshold = 0.40

# --- Copy Get-DisconnectProbability and Get-IntervalPercentile from WifiFix.ps1 here ---
# (The agent should paste the actual functions after implementation)

# ============================================================
# TEST GROUP 1: Get-DisconnectProbability
# ============================================================
Write-Host "`n=== CDF: Get-DisconnectProbability ===" -ForegroundColor Cyan

# 1a: Below minDataPoints returns 0
$intervals = [System.Collections.Generic.List[double]]::new()
$intervals.Add(30); $intervals.Add(60)
Assert "CDF: below minDataPoints returns 0" ((Get-DisconnectProbability 50) -eq 0.0)

# 1b: Basic CDF with known data
$intervals = [System.Collections.Generic.List[double]]::new()
@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100) | ForEach-Object { $intervals.Add($_) }

Assert "CDF: P(5) = 0.0 (below all intervals)" ((Get-DisconnectProbability 5) -eq 0.0)
Assert "CDF: P(10) = 0.1 (1 of 10)" ((Get-DisconnectProbability 10) -eq 0.1)
Assert "CDF: P(50) = 0.5 (5 of 10)" ((Get-DisconnectProbability 50) -eq 0.5)
Assert "CDF: P(100) = 1.0 (all 10)" ((Get-DisconnectProbability 100) -eq 1.0)
Assert "CDF: P(200) = 1.0 (above all)" ((Get-DisconnectProbability 200) -eq 1.0)

# 1c: Outlier resistance — one huge value doesn't affect lower percentiles
$intervals = [System.Collections.Generic.List[double]]::new()
@(30, 40, 50, 60, 70, 80, 90, 100, 110, 32919) | ForEach-Object { $intervals.Add($_) }

Assert "CDF: P(70) with outlier = 0.4 (4 of 10 <= 70)" ((Get-DisconnectProbability 70) -eq 0.4)
Assert "CDF: P(110) with outlier = 0.9 (9 of 10 <= 110)" ((Get-DisconnectProbability 110) -eq 0.9)

# 1d: Window size — only uses last N intervals
$intervals = [System.Collections.Generic.List[double]]::new()
# Add 25 intervals: first 5 are huge (old), last 20 are small (recent)
for ($i = 0; $i -lt 5; $i++) { $intervals.Add(10000) }
for ($i = 1; $i -le 20; $i++) { $intervals.Add($i * 10) }  # 10,20,...,200

# With window=20, only the last 20 (10-200) should be used
Assert "CDF: windowed P(100) = 0.5 (10 of 20 recent)" ((Get-DisconnectProbability 100) -eq 0.5)
# The 5 huge values should be outside the window
Assert "CDF: windowed P(5000) = 1.0 (all recent are below)" ((Get-DisconnectProbability 5000) -eq 1.0)

# ============================================================
# TEST GROUP 2: Get-IntervalPercentile
# ============================================================
Write-Host "`n=== Percentile: Get-IntervalPercentile ===" -ForegroundColor Cyan

$intervals = [System.Collections.Generic.List[double]]::new()
@(10, 20, 30, 40, 50, 60, 70, 80, 90, 100) | ForEach-Object { $intervals.Add($_) }

# 2a: Below minDataPoints returns null
$saved = $intervals
$intervals = [System.Collections.Generic.List[double]]::new()
$intervals.Add(10)
Assert "Percentile: below minDataPoints returns null" ($null -eq (Get-IntervalPercentile 0.5))
$intervals = $saved

# 2b: P50 of evenly spaced 10-100
$p50 = Get-IntervalPercentile 0.5
Assert "Percentile: P50 of 10-100 = 60" ($p50 -eq 60)

# 2c: P90
$p90 = Get-IntervalPercentile 0.9
Assert "Percentile: P90 of 10-100 = 100" ($p90 -eq 100)

# 2d: P25
$p25 = Get-IntervalPercentile 0.25
Assert "Percentile: P25 of 10-100 = 30" ($p25 -eq 30)

# ============================================================
# TEST GROUP 3: No orphaned references
# ============================================================
Write-Host "`n=== Orphaned References ===" -ForegroundColor Cyan

$scriptPath = "$PSScriptRoot\..\WifiFix.ps1"
$content = Get-Content $scriptPath -Raw

$deadSymbols = @(
    '\$emaInterval',
    '\$emaAlpha',
    '\$safetyMarginPct',
    '\$savedPredictDisconnectAt',
    '\$degradationLookaheadPct',
    'Get-PredictedDisconnectTime',
    'Get-AdaptiveSafetyMargin',
    'Get-PredictiveSwapTime'
)

foreach ($sym in $deadSymbols) {
    # Use word-boundary-ish matching: the symbol not inside a comment or string about removal
    $found = [regex]::Matches($content, $sym)
    Assert "No orphan: $sym (found $($found.Count) occurrences)" ($found.Count -eq 0)
}

# ============================================================
# TEST GROUP 4: CSV header format
# ============================================================
Write-Host "`n=== CSV Header ===" -ForegroundColor Cyan

# Check that the script writes the new header (Prob instead of EMA_Seconds)
$headerMatch = $content -match 'Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded'
Assert "CSV header uses 'Prob' column (not EMA_Seconds)" $headerMatch

$oldHeader = $content -match 'Timestamp,Adapter,IntervalSeconds,EMA_Seconds'
Assert "CSV header: old EMA_Seconds header is gone" (-not $oldHeader)

# ============================================================
# TEST GROUP 5: Required new config params exist
# ============================================================
Write-Host "`n=== New Config Params ===" -ForegroundColor Cyan

$requiredParams = @(
    '\$swapProbThreshold',
    '\$returnHoldPctile',
    '\$maxHoldTime',
    '\$degradationProbThreshold',
    '\$predictionWindowSize'
)

foreach ($param in $requiredParams) {
    $found = $content -match [regex]::Escape($param.TrimStart('\'))
    Assert "Config exists: $param" $found
}

# ============================================================
# TEST GROUP 6: Required new functions exist
# ============================================================
Write-Host "`n=== New Functions ===" -ForegroundColor Cyan

Assert "Function exists: Get-DisconnectProbability" ($content -match 'function Get-DisconnectProbability')
Assert "Function exists: Get-IntervalPercentile" ($content -match 'function Get-IntervalPercentile')

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
```

**Instructions for the agent:**
1. Complete all implementation tasks in this PRP first.
2. Copy `Get-DisconnectProbability` and `Get-IntervalPercentile` from the modified `WifiFix.ps1` into the marked locations in the test script.
3. Create the test file at `tests\test_02_cdf_engine.ps1`.
4. Run it: `powershell -File tests\test_02_cdf_engine.ps1`
5. All assertions must pass. Fix any failures before marking this PRP complete.

### Manual verification (cannot be automated)

1. **Probability display:** Run the full script with 5+ historical disconnects. Confirm `P=XX%` increases over time as primary stays up.
2. **Predictive swap fires:** Observe that a swap occurs when the displayed probability reaches ~65%.
3. **Predictive return:** After a predictive swap, observe the script returns to primary after the hold window expires.

## Dependencies

- Requires PRP 01 completed
- PRP 03 (cluster detection) depends on this
- PRP 04 (degradation improvements) depends on this
