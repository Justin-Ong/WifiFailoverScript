# PRP 04: Relative Degradation Thresholds

**Status: Completed**

## Goal

Replace the fixed absolute jitter threshold (`$jitterThreshold = 50ms`) with a relative threshold based on a longer-term latency baseline. This prevents false degradation flags on adapters with naturally higher jitter, and catches degradation on low-jitter adapters that the fixed threshold would miss.

## Prerequisites

- PRP 02 (CDF prediction engine) must be completed. This PRP assumes:
  - The degradation swap trigger uses `$degradationProbThreshold` (a CDF probability) instead of `$degradationLookaheadPct`
  - `Get-LinkDegradation` is called from the predictive swap block to decide whether to use the lower threshold

## Context

- `$latencyWindow` is a `[System.Collections.Generic.List[double]]` sliding window of the last 20 primary latency readings
- `Get-LinkDegradation` computes jitter (stddev) and trend (linear regression slope) over this window
- Degradation is currently flagged when `$jitter -gt $jitterThreshold` (50ms) or `$trend -gt $trendThreshold` (5ms/tick)
- The trend threshold is less problematic (slope is relative by nature) but the jitter threshold is absolute

## New Configuration Parameters

Remove:
```powershell
$jitterThreshold = 50          # ms stddev — above this, link is "jittery"
```

Add:
```powershell
$baselineWindowSize = 100      # sliding window size for long-term baseline
$jitterMultiplier = 2.5        # flag degradation when current jitter exceeds baseline * this
$minJitterThreshold = 15       # ms — absolute floor for jitter threshold (prevents triggering on noise when baseline is very low)
```

Keep `$trendThreshold = 5` unchanged.

## New State Variables

Add to the state section:
```powershell
$baselineLatencyWindow = [System.Collections.Generic.List[double]]::new()
```

## Tasks

### 1. Accumulate baseline latency window

**File:** `WifiFix.ps1`, main loop, where `$latencyWindow` is populated (around line 340)

Currently:
```powershell
if ($pResult.Up -and $pResult.Latency -lt 9999) {
    $latencyWindow.Add([double]$pResult.Latency)
    if ($latencyWindow.Count -gt $latencyWindowSize) {
        $latencyWindow.RemoveAt(0)
    }
}
```

Add baseline accumulation immediately after:
```powershell
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
```

When primary goes down, **do not** clear `$baselineLatencyWindow` (unlike `$latencyWindow` which is cleared). The baseline should persist across brief outages to maintain its longer-term character. Find the existing clear:
```powershell
if (-not $pResult.Up) {
    $latencyWindow.Clear()
}
```

Do NOT add `$baselineLatencyWindow.Clear()` here. The baseline only resets naturally by being overwritten as new samples arrive.

### 2. Update `Get-LinkDegradation` to use relative jitter threshold

**File:** `WifiFix.ps1`, `Get-LinkDegradation` function

Current degradation check:
```powershell
$degraded = ($jitter -gt $jitterThreshold) -or ($trend -gt $trendThreshold)
```

Replace with:
```powershell
# Compute baseline jitter from the longer-term window
$effectiveJitterThreshold = $minJitterThreshold
if ($script:baselineLatencyWindow.Count -ge 30) {
    $blValues = $script:baselineLatencyWindow.ToArray()
    $blMean = ($blValues | Measure-Object -Average).Average
    $blSumSqDiff = 0
    foreach ($v in $blValues) { $blSumSqDiff += ($v - $blMean) * ($v - $blMean) }
    $baselineJitter = [math]::Sqrt($blSumSqDiff / $blValues.Count)
    $effectiveJitterThreshold = [math]::Max($minJitterThreshold, $baselineJitter * $jitterMultiplier)
}

$degraded = ($jitter -gt $effectiveJitterThreshold) -or ($trend -gt $trendThreshold)
```

Also update the return value to include the effective threshold for diagnostics:
```powershell
return @{
    Jitter = [math]::Round($jitter, 1)
    Trend = [math]::Round($trend, 2)
    Degraded = $degraded
    JitterThreshold = [math]::Round($effectiveJitterThreshold, 1)
}
```

### 3. Update degradation display

**File:** `WifiFix.ps1`, main loop, degradation warning display

Currently:
```powershell
if ($deg.Degraded) {
    Write-Host "  [DEGRADED jitter=$($deg.Jitter)ms trend=$($deg.Trend)ms/tick]" -ForegroundColor Yellow
}
```

Update to show the effective threshold:
```powershell
if ($deg.Degraded) {
    Write-Host "  [DEGRADED jitter=$($deg.Jitter)ms(thr=$($deg.JitterThreshold)ms) trend=$($deg.Trend)ms/tick]" -ForegroundColor Yellow
}
```

### 4. Update startup banner

**File:** `WifiFix.ps1`, startup section

Replace the jitter threshold display. Change:
```powershell
Write-Host "Bounce:      ${minStableIntervalFloor}s min stable (adaptive) | Jitter: ${jitterThreshold}ms | Trend: ${trendThreshold}ms/tick"
```

To:
```powershell
Write-Host "Bounce:      ${minStableIntervalFloor}s min stable (adaptive) | Jitter: ${jitterMultiplier}x baseline (floor ${minJitterThreshold}ms) | Trend: ${trendThreshold}ms/tick"
```

## Verification

After completing all changes, create and run `tests\test_04_degradation.ps1` with the following content. All assertions must pass.

```powershell
# test_04_degradation.ps1 — Agent-executable tests for PRP 04
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Config (must match WifiFix.ps1) ---
$latencyWindowSize = 20
$baselineWindowSize = 100
$jitterMultiplier = 2.5
$minJitterThreshold = 15
$trendThreshold = 5

# --- State ---
$latencyWindow = [System.Collections.Generic.List[double]]::new()
$baselineLatencyWindow = [System.Collections.Generic.List[double]]::new()

# --- Copy Get-LinkDegradation from WifiFix.ps1 here ---
# (The agent should paste the actual function after implementation)

# ============================================================
# TEST GROUP 1: Baseline below 30 samples — uses absolute floor
# ============================================================
Write-Host "`n=== Baseline Below Threshold ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
# Add 10 baseline samples (< 30 required)
for ($i = 0; $i -lt 10; $i++) { $baselineLatencyWindow.Add(5) }
# Add 10 latency window samples with high jitter
@(5, 50, 5, 50, 5, 50, 5, 50, 5, 50) | ForEach-Object { $latencyWindow.Add($_) }

$result = Get-LinkDegradation
Assert "Below 30 baseline: uses floor threshold ($minJitterThreshold ms)" ($result.JitterThreshold -eq $minJitterThreshold)
Assert "Below 30 baseline: high jitter detected as degraded" $result.Degraded

# ============================================================
# TEST GROUP 2: Low-jitter adapter (stable baseline)
# ============================================================
Write-Host "`n=== Low-Jitter Adapter ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
# Baseline: 50 samples of ~2ms (stddev ≈ 0)
for ($i = 0; $i -lt 50; $i++) { $baselineLatencyWindow.Add(2) }
# Current window: stable at 2ms
for ($i = 0; $i -lt 10; $i++) { $latencyWindow.Add(2) }

$result = Get-LinkDegradation
# Baseline jitter ≈ 0, so effective threshold = max(15, 0 * 2.5) = 15
Assert "Low-jitter: threshold is floor ($minJitterThreshold ms)" ($result.JitterThreshold -eq $minJitterThreshold)
Assert "Low-jitter: stable link is NOT degraded" (-not $result.Degraded)

# Now spike the current window
$latencyWindow.Clear()
@(2, 2, 2, 50, 2, 50, 2, 50, 2, 50) | ForEach-Object { $latencyWindow.Add($_) }
$result = Get-LinkDegradation
Assert "Low-jitter: spike above floor IS degraded" $result.Degraded

# ============================================================
# TEST GROUP 3: High-jitter adapter (noisy baseline)
# ============================================================
Write-Host "`n=== High-Jitter Adapter ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
# Baseline: 50 samples alternating 10ms and 50ms (mean=30, stddev≈20)
for ($i = 0; $i -lt 50; $i++) {
    if ($i % 2 -eq 0) { $baselineLatencyWindow.Add(10) } else { $baselineLatencyWindow.Add(50) }
}

# Current window: normal noisy pattern (same as baseline)
$latencyWindow.Clear()
for ($i = 0; $i -lt 10; $i++) {
    if ($i % 2 -eq 0) { $latencyWindow.Add(10) } else { $latencyWindow.Add(50) }
}

$result = Get-LinkDegradation
# Baseline stddev ≈ 20. Threshold = max(15, 20 * 2.5) = 50.
# Current jitter ≈ 20, which is below 50.
Assert "High-jitter: threshold is ~50ms (baseline_stddev * 2.5)" ($result.JitterThreshold -ge 45 -and $result.JitterThreshold -le 55)
Assert "High-jitter: normal noise is NOT degraded" (-not $result.Degraded)

# Now add extreme jitter to current window
$latencyWindow.Clear()
@(10, 200, 10, 200, 10, 200, 10, 200, 10, 200) | ForEach-Object { $latencyWindow.Add($_) }
$result = Get-LinkDegradation
# Current jitter ≈ 95, well above threshold of ~50
Assert "High-jitter: extreme spike IS degraded" $result.Degraded
Assert "High-jitter: measured jitter > threshold" ($result.Jitter -gt $result.JitterThreshold)

# ============================================================
# TEST GROUP 4: Trend detection (independent of jitter changes)
# ============================================================
Write-Host "`n=== Trend Detection ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
for ($i = 0; $i -lt 50; $i++) { $baselineLatencyWindow.Add(10) }

# Rising latency: 10, 15, 20, ..., 60 (slope ≈ 5ms/tick)
for ($i = 0; $i -lt 11; $i++) { $latencyWindow.Add(10 + $i * 5) }

$result = Get-LinkDegradation
Assert "Trend: rising latency detected (trend=$($result.Trend))" ($result.Trend -ge $trendThreshold)
Assert "Trend: rising latency IS degraded" $result.Degraded

# Flat latency — no trend
$latencyWindow.Clear()
for ($i = 0; $i -lt 10; $i++) { $latencyWindow.Add(10) }
$result = Get-LinkDegradation
Assert "Trend: flat latency not degraded (trend=$($result.Trend))" (-not $result.Degraded)

# ============================================================
# TEST GROUP 5: JitterThreshold in return value
# ============================================================
Write-Host "`n=== Return Value Structure ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
for ($i = 0; $i -lt 50; $i++) { $baselineLatencyWindow.Add(5) }
for ($i = 0; $i -lt 10; $i++) { $latencyWindow.Add(5) }

$result = Get-LinkDegradation
Assert "Return has Jitter key" ($null -ne $result.Jitter)
Assert "Return has Trend key" ($null -ne $result.Trend)
Assert "Return has Degraded key" ($null -ne $result.Degraded)
Assert "Return has JitterThreshold key" ($null -ne $result.JitterThreshold)

# ============================================================
# TEST GROUP 6: Code structure checks
# ============================================================
Write-Host "`n=== Code Structure ===" -ForegroundColor Cyan

$scriptPath = "$PSScriptRoot\..\WifiFix.ps1"
$content = Get-Content $scriptPath -Raw

Assert "Config exists: baselineWindowSize" ($content -match '\$baselineWindowSize')
Assert "Config exists: jitterMultiplier" ($content -match '\$jitterMultiplier')
Assert "Config exists: minJitterThreshold" ($content -match '\$minJitterThreshold')
Assert "State var: baselineLatencyWindow" ($content -match '\$baselineLatencyWindow')
Assert "Old fixed jitterThreshold removed" (-not ($content -match '\$jitterThreshold\s*=\s*50'))

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
```

**Instructions for the agent:**
1. Complete all implementation tasks in this PRP first.
2. Copy `Get-LinkDegradation` from the modified `WifiFix.ps1` into the marked location in the test script.
3. Create the test file at `tests\test_04_degradation.ps1`.
4. Run it: `powershell -File tests\test_04_degradation.ps1`
5. All assertions must pass. Fix any failures before marking this PRP complete.

### Manual verification (cannot be automated)

1. **Baseline buildup:** Run the full script and watch for the effective threshold in the `[DEGRADED]` display to change from the floor value as baseline accumulates.
2. **Baseline persistence:** Observe that after a brief primary outage and recovery, the degradation threshold doesn't reset to the floor.

## Dependencies

- Requires PRP 02 completed (for `$degradationProbThreshold` integration)
- Can be done in parallel with PRP 03 (cluster detection) — no overlapping code
- PRP 05 (documentation) should be done after this
