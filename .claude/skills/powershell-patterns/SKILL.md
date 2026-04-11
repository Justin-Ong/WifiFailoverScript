---
name: powershell-patterns
description: PowerShell systems programming patterns including RunspacePool concurrency, atomic snapshots for cross-thread state, rolling windows, empirical CDF, and Windows networking APIs.
---

# PowerShell Systems Programming Patterns

## When to Activate

Use this skill when:
- Writing new PowerShell functions
- Working with runspaces and concurrency
- Handling cross-thread state
- Parsing and processing data
- Interacting with Windows networking APIs

## Concurrency Patterns

### RunspacePool for Background Work
```powershell
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
$runspacePool.Open()

$script = {
    param($adapterIP, $target, $state)
    while ($true) {
        try {
            $result = ping.exe -S $adapterIP $target -n 1 -w 1000
            $ms = if ($result -match 'time[=<](\d+)') { [int]$Matches[1] } else { 0 }
            $up = $result -match 'TTL='
            $state.Value = [PSCustomObject]@{ Up = $up; Latency = $ms; Updated = Get-Date }
        } catch {
            $state.Value = [PSCustomObject]@{ Up = $false; Latency = 0; Updated = Get-Date }
        }
        Start-Sleep -Milliseconds 500
    }
}

$ps = [PowerShell]::Create().AddScript($script).AddArgument($ip).AddArgument($target).AddArgument($state)
$ps.RunspacePool = $runspacePool
$handle = $ps.BeginInvoke()
```

### Atomic Snapshot Pattern
```powershell
# Synchronized hashtable for thread-safe reference container
$state = [hashtable]::Synchronized(@{ Value = $null })

# Writer (background thread): replace entire snapshot atomically
$state.Value = [PSCustomObject]@{ Up = $true; Latency = 45; Updated = Get-Date }

# Reader (main thread): read atomic reference
$snapshot = $state.Value
if ($snapshot.Up -and $snapshot.Latency -lt $threshold) { ... }
```

### Staleness Guard
```powershell
$age = (Get-Date) - $snapshot.Updated
$isUp = if ($age.TotalSeconds -gt $staleProbeThreshold) { $false } else { $snapshot.Up }
```

## Data Processing Patterns

### Rolling Window with Generic List
```powershell
$window = [System.Collections.Generic.List[double]]::new()

# Add new sample
$window.Add($latency)

# Trim to window size
while ($window.Count -gt $windowSize) {
    $window.RemoveAt(0)
}

# Slice without full copy
$recent = $window.GetRange([Math]::Max(0, $window.Count - $n), [Math]::Min($n, $window.Count))
```

### Empirical CDF Calculation
```powershell
function Get-DisconnectProbability($elapsedSeconds) {
    if ($script:intervals.Count -lt $script:minDataPoints) { return 0.0 }

    $window = if ($script:predictionWindowSize -gt 0 -and $script:intervals.Count -gt $script:predictionWindowSize) {
        $script:intervals.GetRange($script:intervals.Count - $script:predictionWindowSize, $script:predictionWindowSize)
    } else {
        $script:intervals
    }

    $count = ($window | Where-Object { $_ -le $elapsedSeconds }).Count
    return [double]$count / $window.Count
}
```

### Standard Deviation
```powershell
$mean = ($samples | Measure-Object -Average).Average
$variance = ($samples | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Average).Average
$stddev = [Math]::Sqrt($variance)
```

### Linear Regression Slope
```powershell
$n = $samples.Count
$sumX = 0; $sumY = 0; $sumXY = 0; $sumX2 = 0
for ($i = 0; $i -lt $n; $i++) {
    $sumX += $i; $sumY += $samples[$i]
    $sumXY += $i * $samples[$i]; $sumX2 += $i * $i
}
$slope = ($n * $sumXY - $sumX * $sumY) / ($n * $sumX2 - $sumX * $sumX)
```

## Windows Networking Patterns

### Set Adapter Priority via Interface Metric
```powershell
try {
    Set-NetIPInterface -InterfaceAlias $adapterName -InterfaceMetric $metric -ErrorAction Stop
    return $true
} catch {
    Write-Host "Failed to set metric: $_" -ForegroundColor Red
    return $false
}
```

### Validate Adapter Exists
```powershell
$adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
if (-not $adapter -or $adapter.Status -ne 'Up') {
    Write-Host "Adapter '$adapterName' not available" -ForegroundColor Red
    return
}
```

## CSV Persistence Patterns

### Corruption-Tolerant Line Parsing
```powershell
$lines = Get-Content $logPath -ErrorAction SilentlyContinue
foreach ($line in $lines) {
    $parts = $line -split ','
    if ($parts.Count -lt 3) { continue }  # Skip corrupt lines

    $interval = 0.0
    if (-not [double]::TryParse($parts[2], [ref]$interval)) { continue }
    if ($interval -lt $floor) { continue }  # Bounce filter

    $intervals.Add($interval)
}
```

### Append-Only Logging with Trim
```powershell
# Append new entry
"$timestamp,$adapter,$interval,$prob,$jitter,$trend,$degraded,$cluster" |
    Add-Content -Path $logPath

# Periodic trim (keep header + last N lines)
if ($disconnectCount % 50 -eq 0) {
    $lines = Get-Content $logPath
    if ($lines.Count -gt $maxLogLines) {
        $lines[0]  # Header
        $lines[($lines.Count - $maxLogLines)..($lines.Count - 1)]  # Last N
        | Set-Content $logPath
    }
}
```

## Best Practices

1. **No Invoke-Expression** - Always use direct cmdlet calls
2. **-ErrorAction Stop** - On all system-modifying cmdlets
3. **[ref] for TryParse** - Safe numeric conversion
4. **Generic Lists** - Not arrays, for efficient Add/Remove operations
5. **Atomic snapshots** - Never mutate cross-thread objects in place
6. **Staleness guards** - Always check timestamp age before trusting probe data
