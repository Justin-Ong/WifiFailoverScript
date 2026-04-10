# Analyse disconnect_log.csv for patterns that suggest gradual link decay
# (clusters of accelerating disconnects) vs. sudden hard drops.

$logPath = Join-Path $PSScriptRoot "disconnect_log.csv"
$rows = Import-Csv $logPath | Where-Object { $_.Adapter -eq "Wi-Fi 2" }

$intervals = $rows | ForEach-Object { [double]$_.IntervalSeconds }
$timestamps = $rows | ForEach-Object { [datetime]$_.Timestamp }

Write-Host "=== Disconnect Log Analysis ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total disconnects: $($rows.Count)"
Write-Host "Time span: $($timestamps[0]) to $($timestamps[-1])"
Write-Host ""

# --- Basic interval stats ---
$sorted = $intervals | Sort-Object
$mean = ($intervals | Measure-Object -Average).Average
$median = $sorted[[math]::Floor($sorted.Count / 2)]
$min = $sorted[0]
$max = $sorted[-1]

Write-Host "=== Interval Statistics ===" -ForegroundColor Cyan
Write-Host ("  Mean:   {0:N1}s" -f $mean)
Write-Host ("  Median: {0:N1}s" -f $median)
Write-Host ("  Min:    {0:N1}s  Max: {1:N1}s" -f $min, $max)
Write-Host ""

# --- Distribution buckets ---
$buckets = @{
    "Bounce (<8s)"     = ($intervals | Where-Object { $_ -lt 8 }).Count
    "Short (8-20s)"    = ($intervals | Where-Object { $_ -ge 8 -and $_ -lt 20 }).Count
    "Medium (20-60s)"  = ($intervals | Where-Object { $_ -ge 20 -and $_ -lt 60 }).Count
    "Long (60-180s)"   = ($intervals | Where-Object { $_ -ge 60 -and $_ -lt 180 }).Count
    "Very long (180s+)" = ($intervals | Where-Object { $_ -ge 180 }).Count
}

Write-Host "=== Interval Distribution ===" -ForegroundColor Cyan
foreach ($b in "Bounce (<8s)", "Short (8-20s)", "Medium (20-60s)", "Long (60-180s)", "Very long (180s+)") {
    $count = $buckets[$b]
    $pct = ($count / $intervals.Count) * 100
    $bar = "#" * [math]::Round($pct / 2)
    Write-Host ("  {0,-20} {1,4} ({2,5:N1}%) {3}" -f $b, $count, $pct, $bar)
}
Write-Host ""

# --- Cluster detection ---
# A "cluster" is 3+ disconnects within 60 seconds of each other.
# Within a cluster, check if intervals are *decreasing* (accelerating failure = gradual decay signature).
Write-Host "=== Cluster Analysis (3+ disconnects within 60s gaps) ===" -ForegroundColor Cyan
Write-Host "  Looking for accelerating failure patterns (gradual decay signature)..." -ForegroundColor Gray
Write-Host ""

$clusterGapThreshold = 60  # seconds between consecutive disconnects to be in same cluster
$clusters = @()
$currentCluster = @(@{ Timestamp = $timestamps[0]; Interval = $intervals[0] })

for ($i = 1; $i -lt $timestamps.Count; $i++) {
    $gap = ($timestamps[$i] - $timestamps[$i - 1]).TotalSeconds
    if ($gap -le $clusterGapThreshold) {
        $currentCluster += @{ Timestamp = $timestamps[$i]; Interval = $intervals[$i] }
    } else {
        if ($currentCluster.Count -ge 3) {
            $clusters += ,@($currentCluster)
        }
        $currentCluster = @(@{ Timestamp = $timestamps[$i]; Interval = $intervals[$i] })
    }
}
if ($currentCluster.Count -ge 3) {
    $clusters += ,@($currentCluster)
}

$acceleratingClusters = 0
$totalClusterDisconnects = 0

foreach ($cluster in $clusters) {
    $totalClusterDisconnects += $cluster.Count

    # Check if intervals trend downward within cluster (excluding bounces)
    $clusterIntervals = $cluster | ForEach-Object { $_.Interval } | Where-Object { $_ -ge 8 }
    $isAccelerating = $false
    if ($clusterIntervals.Count -ge 2) {
        $decreasing = 0
        for ($i = 1; $i -lt $clusterIntervals.Count; $i++) {
            if ($clusterIntervals[$i] -lt $clusterIntervals[$i - 1]) { $decreasing++ }
        }
        $isAccelerating = ($decreasing / ($clusterIntervals.Count - 1)) -ge 0.5
    }
    if ($isAccelerating) { $acceleratingClusters++ }
}

Write-Host ("  Total clusters found: {0}" -f $clusters.Count)
Write-Host ("  Disconnects in clusters: {0}/{1} ({2:N1}%)" -f $totalClusterDisconnects, $rows.Count, (($totalClusterDisconnects / $rows.Count) * 100))
Write-Host ("  Clusters with accelerating intervals: {0}/{1}" -f $acceleratingClusters, $clusters.Count)
Write-Host ""

# --- Show example clusters ---
if ($clusters.Count -gt 0) {
    $showCount = [math]::Min(5, $clusters.Count)
    Write-Host "=== Example Clusters (first $showCount) ===" -ForegroundColor Cyan
    for ($c = 0; $c -lt $showCount; $c++) {
        $cluster = $clusters[$c]
        $clusterIntervals = $cluster | ForEach-Object { $_.Interval }
        $nonBounce = $clusterIntervals | Where-Object { $_ -ge 8 }
        $isAccel = $false
        if ($nonBounce.Count -ge 2) {
            $dec = 0
            for ($i = 1; $i -lt $nonBounce.Count; $i++) {
                if ($nonBounce[$i] -lt $nonBounce[$i - 1]) { $dec++ }
            }
            $isAccel = ($dec / ($nonBounce.Count - 1)) -ge 0.5
        }
        $tag = if ($isAccel) { " [ACCELERATING]" } else { "" }
        Write-Host ("  Cluster {0}: {1} disconnects at {2}{3}" -f ($c + 1), $cluster.Count, $cluster[0].Timestamp, $tag) -ForegroundColor Yellow
        foreach ($entry in $cluster) {
            $intTag = if ($entry.Interval -lt 8) { " (bounce)" } else { "" }
            Write-Host ("    {0}  interval={1}s{2}" -f $entry.Timestamp, $entry.Interval, $intTag)
        }
        Write-Host ""
    }
}

# --- Sudden vs. gradual assessment ---
Write-Host "=== Verdict ===" -ForegroundColor Cyan
$clusterPct = if ($rows.Count -gt 0) { ($totalClusterDisconnects / $rows.Count) * 100 } else { 0 }
$accelPct = if ($clusters.Count -gt 0) { ($acceleratingClusters / $clusters.Count) * 100 } else { 0 }

if ($clusterPct -gt 50 -and $accelPct -gt 30) {
    Write-Host "  STRONG evidence for gradual decay pattern." -ForegroundColor Green
    Write-Host "  Most disconnects come in clusters, and many show accelerating intervals."
    Write-Host "  Link degradation detection would likely catch the early warning signs."
} elseif ($clusterPct -gt 30) {
    Write-Host "  MODERATE evidence for gradual decay pattern." -ForegroundColor Yellow
    Write-Host "  A significant portion of disconnects are clustered."
    Write-Host "  Link degradation detection could help with the clustered cases."
} else {
    Write-Host "  WEAK evidence for gradual decay pattern." -ForegroundColor Red
    Write-Host "  Most disconnects appear as isolated sudden drops."
    Write-Host "  Link degradation detection may have limited value with this adapter's failure mode."
}

Write-Host ""
Write-Host "  NOTE: This analysis is indirect. The logs don't record per-ping latency," -ForegroundColor Gray
Write-Host "  so we can't confirm whether latency actually rose before each drop." -ForegroundColor Gray
Write-Host "  Clusters of accelerating disconnects are circumstantial evidence only." -ForegroundColor Gray
Write-Host "  To get definitive data, run the updated script and check for [DEGRADED]" -ForegroundColor Gray
Write-Host "  warnings that precede actual disconnects." -ForegroundColor Gray
