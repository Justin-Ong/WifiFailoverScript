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

# --- Function from WifiFix-Functions.ps1 ---
. "$PSScriptRoot\..\WifiFix-Functions.ps1"

# ============================================================
# TEST GROUP 1: Baseline below 30 samples — uses absolute floor
# ============================================================
Write-Host "`n=== Baseline Below Threshold ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
for ($i = 0; $i -lt 10; $i++) { $baselineLatencyWindow.Add(5) }
@(5, 50, 5, 50, 5, 50, 5, 50, 5, 50) | ForEach-Object { $latencyWindow.Add($_) }

$result = Get-LinkDegradation
Assert "Below 30 baseline: uses floor threshold ($minJitterThreshold ms)" ($result.JitterThreshold -eq $minJitterThreshold)
Assert "Below 30 baseline: high jitter detected as degraded" $result.Degraded

# ============================================================
# TEST GROUP 2: Low-jitter adapter (stable baseline)
# ============================================================
Write-Host "`n=== Low-Jitter Adapter ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
for ($i = 0; $i -lt 50; $i++) { $baselineLatencyWindow.Add(2) }
for ($i = 0; $i -lt 10; $i++) { $latencyWindow.Add(2) }

$result = Get-LinkDegradation
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
for ($i = 0; $i -lt 50; $i++) {
    if ($i % 2 -eq 0) { $baselineLatencyWindow.Add(10) } else { $baselineLatencyWindow.Add(50) }
}

$latencyWindow.Clear()
for ($i = 0; $i -lt 10; $i++) {
    if ($i % 2 -eq 0) { $latencyWindow.Add(10) } else { $latencyWindow.Add(50) }
}

$result = Get-LinkDegradation
Assert "High-jitter: threshold is ~50ms (baseline_stddev * 2.5)" ($result.JitterThreshold -ge 45 -and $result.JitterThreshold -le 55)
Assert "High-jitter: normal noise is NOT degraded" (-not $result.Degraded)

# Now add extreme jitter to current window
$latencyWindow.Clear()
@(10, 200, 10, 200, 10, 200, 10, 200, 10, 200) | ForEach-Object { $latencyWindow.Add($_) }
$result = Get-LinkDegradation
Assert "High-jitter: extreme spike IS degraded" $result.Degraded
Assert "High-jitter: measured jitter > threshold" ($result.Jitter -gt $result.JitterThreshold)

# ============================================================
# TEST GROUP 4: Trend detection (independent of jitter changes)
# ============================================================
Write-Host "`n=== Trend Detection ===" -ForegroundColor Cyan

$latencyWindow.Clear(); $baselineLatencyWindow.Clear()
for ($i = 0; $i -lt 50; $i++) { $baselineLatencyWindow.Add(10) }

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
