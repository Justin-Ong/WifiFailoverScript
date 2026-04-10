# WifiFix-Functions.ps1 — Shared helper functions extracted from WifiFix.ps1
# Dot-source this file in tests to avoid copy-pasting function implementations.
# The main script (WifiFix.ps1) also dot-sources this file.

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

function Update-ClusterState {
    param([double]$interval)
    if ($interval -le $clusterGapThreshold) {
        $script:clusterDisconnects++
        if ($script:clusterDisconnects -ge 2) {
            if (-not $script:inCluster) {
                Write-Host "  [CLUSTER DETECTED: $($script:clusterDisconnects) disconnects in rapid succession]" -ForegroundColor Yellow
            }
            $script:inCluster = $true
        }
    } else {
        # Gap exceeded threshold — this disconnect starts a new sequence
        if ($script:inCluster) {
            Write-Host "  [CLUSTER ENDED after $($script:clusterDisconnects) disconnects]" -ForegroundColor DarkYellow
            $script:lastClusterEnd = Get-Date
        }
        $script:inCluster = $false
        $script:clusterDisconnects = 1
    }
}

function Get-LinkDegradation {
    if ($script:latencyWindow.Count -lt 5) {
        return @{ Jitter = 0; Trend = 0; Degraded = $false; JitterThreshold = $minJitterThreshold }
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
    return @{ Jitter = [math]::Round($jitter, 1); Trend = [math]::Round($trend, 2); Degraded = $degraded; JitterThreshold = [math]::Round($effectiveJitterThreshold, 1) }
}

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
