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

# --- Functions from WifiFix-Functions.ps1 ---
. "$PSScriptRoot\..\WifiFix-Functions.ps1"

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

# 1c: Outlier resistance
$intervals = [System.Collections.Generic.List[double]]::new()
@(30, 40, 50, 60, 70, 80, 90, 100, 110, 32919) | ForEach-Object { $intervals.Add($_) }

Assert "CDF: P(70) with outlier = 0.5 (5 of 10 <= 70)" ((Get-DisconnectProbability 70) -eq 0.5)
Assert "CDF: P(110) with outlier = 0.9 (9 of 10 <= 110)" ((Get-DisconnectProbability 110) -eq 0.9)

# 1d: Window size — only uses last N intervals
$intervals = [System.Collections.Generic.List[double]]::new()
for ($i = 0; $i -lt 5; $i++) { $intervals.Add(10000) }
for ($i = 1; $i -le 20; $i++) { $intervals.Add($i * 10) }

Assert "CDF: windowed P(100) = 0.5 (10 of 20 recent)" ((Get-DisconnectProbability 100) -eq 0.5)
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
    $found = [regex]::Matches($content, $sym)
    Assert "No orphan: $sym (found $($found.Count) occurrences)" ($found.Count -eq 0)
}

# ============================================================
# TEST GROUP 4: CSV header format
# ============================================================
Write-Host "`n=== CSV Header ===" -ForegroundColor Cyan

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

$fnContent = Get-Content "$PSScriptRoot\..\WifiFix-Functions.ps1" -Raw
Assert "Function exists: Get-DisconnectProbability" ($fnContent -match 'function Get-DisconnectProbability')
Assert "Function exists: Get-IntervalPercentile" ($fnContent -match 'function Get-IntervalPercentile')

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
