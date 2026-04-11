# Common Patterns

## Atomic Snapshot Pattern (Cross-Thread State)

```powershell
# Background thread writes entire snapshot as one object
$state.Value = [PSCustomObject]@{
    Up      = $true
    Latency = 45
    Updated = Get-Date
}

# Main loop reads atomically (reference assignment)
$snapshot = $state.Value
if ($snapshot.Up) { ... }
```

## RunspacePool Concurrency

```powershell
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
$runspacePool.Open()

$ps = [PowerShell]::Create().AddScript($pingScript).AddArgument($adapter)
$ps.RunspacePool = $runspacePool
$handle = $ps.BeginInvoke()
```

## CDF Probability Model

```powershell
function Get-DisconnectProbability($elapsedSeconds) {
    # Empirical CDF: count(intervals <= elapsed) / count(intervals)
    # Recency-biased: uses last $predictionWindowSize intervals
    # Returns 0.0 if fewer than $minDataPoints intervals
}
```

## Adaptive Threshold Pattern

```powershell
# Instead of fixed thresholds, derive from data
$baseline = StdDev(last 100 samples)
$threshold = [Math]::Max($absoluteFloor, $baseline * $multiplier)
```

## Staleness Guard

```powershell
# Treat stale data as failure, not stale success
$age = (Get-Date) - $snapshot.Updated
if ($age.TotalSeconds -gt $staleProbeThreshold) {
    $isUp = $false  # Stale = assume down
}
```

## Color-Coded Console Output

```powershell
# Consistent color scheme across the project
Write-Host "message" -ForegroundColor Green     # Healthy, success
Write-Host "message" -ForegroundColor Red       # Failed, down
Write-Host "message" -ForegroundColor Yellow    # Warnings, degradation
Write-Host "message" -ForegroundColor Blue      # Predictive actions
Write-Host "message" -ForegroundColor Magenta   # Failover events
Write-Host "message" -ForegroundColor DarkGray  # Informational
```

## CSV Disconnect Log Format

```
Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster
2026-04-09 14:30:15,Wi-Fi 2,342,0.72,32.5,3.12,False,False
```

- Index-based field parsing (not header-based) for backward compatibility
- New columns always appended at end
- Corrupt lines skipped silently during load

## Bounce Filter Pattern

```powershell
# Adaptive floor prevents noise from polluting the model
$floor = Get-MinStableInterval  # max($minStableIntervalFloor, median × 0.20)
if ($interval -ge $floor) {
    $intervals.Add($interval)   # Model-quality data
}
# Bounces still logged to CSV but excluded from CDF model
```
