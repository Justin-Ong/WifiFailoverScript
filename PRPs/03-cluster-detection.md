# PRP 03: Cluster Detection

**Status: Completed**

## Goal

Detect when disconnects are occurring in rapid bursts and adjust behavior to stay on the secondary adapter for the duration of the burst instead of ping-ponging between adapters.

## Prerequisites

- PRP 01 (data pipeline fixes) must be completed
- PRP 02 (CDF prediction engine) must be completed. This PRP assumes:
  - Predictive swap uses `Get-DisconnectProbability` with `$swapProbThreshold`
  - Predictive return uses `Get-IntervalPercentile $returnHoldPctile` and `$maxHoldTime`
  - `$emaInterval` no longer exists

## Context

The disconnect log shows clear burst patterns: several disconnects within 1–3 minutes, then a calm period. During bursts, the current behavior is: predictive swap → wait → return → immediately drop → reactive swap → repeat. With cluster awareness, the script should stay on secondary through the entire burst.

## New Configuration Parameters

Add to the configuration section:
```powershell
$clusterGapThreshold = 120     # seconds — disconnects closer than this are part of the same cluster
$clusterHoldMultiplier = 2.0   # multiply return hold time when in a cluster
$clusterCooldownInterval = 300 # seconds — after a cluster ends, wait this long before trusting primary fully
```

## New State Variables

Add to the state section:
```powershell
$inCluster = $false
$clusterDisconnects = 0
$lastClusterEnd = $null         # when the last cluster was considered over
```

## Tasks

### 1. Add cluster detection function

**File:** `WifiFix.ps1`, after the `Get-DisconnectProbability` / `Get-IntervalPercentile` functions (added by PRP 02)

```powershell
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
```

The function uses the interval (time since last disconnect / prediction base) to determine proximity. Two or more disconnects within `$clusterGapThreshold` of each other triggers cluster mode.

### 2. Call cluster detection from `Write-DisconnectLog`

**File:** `WifiFix.ps1`, `Write-DisconnectLog` function

Add a call to `Update-ClusterState` after the interval is computed and validated, but before the CSV append. Place it right after the `$intervals.Add($interval)` block:

```powershell
# After the interval has been computed and (possibly) added to $intervals:
if ($interval -gt 0) {
    Update-ClusterState $interval
}
```

This should go after the bounce filtering check — the cluster detector receives the raw interval (including bounces), because a rapid sequence of bounces IS a cluster signal even if individual intervals are too short for the prediction model.

### 3. Modify predictive return to hold longer during clusters

**File:** `WifiFix.ps1`, main loop, the "PREDICTIVE RETURN (CDF-based)" block (added by PRP 02)

In the return logic, multiply the hold time when `$inCluster` is true. Change the hold computation:

```powershell
if ($predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
    $elapsed = ($now - $predictionBaseTime).TotalSeconds
    $returnAfterInterval = Get-IntervalPercentile $returnHoldPctile

    # During a cluster, extend the hold time
    if ($inCluster -and $null -ne $returnAfterInterval) {
        $returnAfterInterval = $returnAfterInterval * $clusterHoldMultiplier
    }

    $holdExpired = ($null -ne $returnAfterInterval -and $elapsed -gt $returnAfterInterval)
    $hardTimeout = ($now - $lastSwapTime).TotalSeconds -gt ($maxHoldTime * $(if ($inCluster) { $clusterHoldMultiplier } else { 1 }))

    if ($holdExpired -or $hardTimeout) {
        $reason = if ($hardTimeout) { "max hold time" } else { "disconnect window passed" }
        if ($inCluster) { $reason += " (cluster)" }
        # ... rest of return logic unchanged
    }
}
```

Both the percentile-based hold and the hard timeout are multiplied by `$clusterHoldMultiplier` during clusters.

### 4. Modify non-predictive recovery to respect cluster state

**File:** `WifiFix.ps1`, main loop, the "Swap back to primary once it recovers" block in the secondary-active section

Currently, this block returns to primary after `$recoveryThreshold` consecutive good pings. During a cluster, this should be harder to trigger. Modify:

```powershell
if (-not $predictivelySwapped -and $pResult.Up -and $pResult.Latency -le $latencyThreshold) {
    $primaryRecoveredCount++
    # During a cluster or shortly after one, require more recovery evidence
    $effectiveThreshold = $recoveryThreshold
    if ($inCluster) {
        $effectiveThreshold = $recoveryThreshold * $clusterHoldMultiplier
    } elseif ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
        # Recently exited a cluster — use intermediate threshold
        $effectiveThreshold = [math]::Ceiling($recoveryThreshold * 1.5)
    }
    if ($primaryRecoveredCount -ge $effectiveThreshold) {
        Write-Host "  FAILBACK -> $primary (primary recovered)" -ForegroundColor Magenta
        $result = Switch-To $primary "failback - primary recovered"
        # ... rest unchanged
    }
} else {
    $primaryRecoveredCount = 0
}
```

### 5. Lower CDF swap threshold during cluster cooldown

**File:** `WifiFix.ps1`, main loop, the "PREDICTIVE SWAP (CDF-based)" block (added by PRP 02)

After a cluster recently ended, be more aggressive about predictive swapping since another burst is likely. Add before the threshold comparison:

```powershell
$threshold = $swapProbThreshold
$degradation = Get-LinkDegradation
if ($degradation.Degraded) {
    $threshold = $degradationProbThreshold
}
# Recently exited a cluster — lower threshold for earlier swap
if ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
    $threshold = [math]::Min($threshold, $degradationProbThreshold)
}
```

### 6. Add cluster state to display

**File:** `WifiFix.ps1`, main loop, display section

Add a cluster indicator to the status line. After the prediction string, before `Write-Host`:

```powershell
$clusterStr = ""
if ($inCluster) {
    $clusterStr = " [CLUSTER x$clusterDisconnects]"
} elseif ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval) {
    $remaining = [math]::Round($clusterCooldownInterval - ($now - $lastClusterEnd).TotalSeconds)
    $clusterStr = " [POST-CLUSTER ${remaining}s]"
}
```

Then append `$clusterStr` to the display output, e.g. after the prediction string using the same DarkYellow color.

### 7. Update startup banner

**File:** `WifiFix.ps1`, startup section

Add a line for cluster config:
```powershell
Write-Host "Cluster:     ${clusterGapThreshold}s gap | ${clusterHoldMultiplier}x hold | ${clusterCooldownInterval}s cooldown"
```

### 8. Add cluster state to CSV (optional but recommended)

**File:** `WifiFix.ps1`, `Write-DisconnectLog` and log file header

Append a `Cluster` column to the CSV:
- Header: `Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster`
- Value: `$inCluster`

This enables post-hoc analysis of cluster patterns. Update the new-file header and the append line. The log loader (PRP 01) uses index-based parsing and only reads up to index 2, so adding a column at the end is backward-compatible.

## Verification

After completing all changes, create and run `tests\test_03_cluster_detection.ps1` with the following content. All assertions must pass.

```powershell
# test_03_cluster_detection.ps1 — Agent-executable tests for PRP 03
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0

function Assert($name, $condition) {
    if ($condition) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Config (must match WifiFix.ps1) ---
$clusterGapThreshold = 120
$clusterHoldMultiplier = 2.0
$clusterCooldownInterval = 300
$recoveryThreshold = 10

# --- State ---
$inCluster = $false
$clusterDisconnects = 0
$lastClusterEnd = $null

# --- Copy Update-ClusterState from WifiFix.ps1 here ---
# (The agent should paste the actual function after implementation)

# ============================================================
# TEST GROUP 1: Cluster state transitions
# ============================================================
Write-Host "`n=== Cluster State Machine ===" -ForegroundColor Cyan

# Reset state
$inCluster = $false; $clusterDisconnects = 0; $lastClusterEnd = $null

# 1a: First disconnect — not a cluster yet
Update-ClusterState 200  # gap > threshold, starts new sequence
Assert "First disconnect: not in cluster" (-not $inCluster)
Assert "First disconnect: clusterDisconnects = 1" ($clusterDisconnects -eq 1)

# 1b: Second disconnect within gap — still not cluster (count = 2, triggers cluster)
Update-ClusterState 60   # gap < 120s
Assert "Second disconnect (within gap): in cluster" $inCluster
Assert "Second disconnect: clusterDisconnects = 2" ($clusterDisconnects -eq 2)

# 1c: Third disconnect within gap — still in cluster
Update-ClusterState 30
Assert "Third disconnect: still in cluster" $inCluster
Assert "Third disconnect: clusterDisconnects = 3" ($clusterDisconnects -eq 3)

# 1d: Disconnect after long gap — cluster ends
Update-ClusterState 200  # gap > threshold
Assert "Long gap: cluster ended" (-not $inCluster)
Assert "Long gap: lastClusterEnd is set" ($null -ne $lastClusterEnd)
Assert "Long gap: clusterDisconnects reset to 1" ($clusterDisconnects -eq 1)

# ============================================================
# TEST GROUP 2: Recovery threshold scaling
# ============================================================
Write-Host "`n=== Recovery Threshold Scaling ===" -ForegroundColor Cyan

# 2a: During cluster
$inCluster = $true
$effectiveThreshold = $recoveryThreshold * $clusterHoldMultiplier
Assert "In-cluster recovery threshold: $effectiveThreshold (base $recoveryThreshold x $clusterHoldMultiplier)" ($effectiveThreshold -eq 20)

# 2b: Post-cluster cooldown
$inCluster = $false
$lastClusterEnd = (Get-Date).AddSeconds(-100)  # 100s ago, within 300s cooldown
$now = Get-Date
$inCooldown = ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval)
Assert "Post-cluster cooldown active (100s ago < 300s window)" $inCooldown
$effectiveThreshold = [math]::Ceiling($recoveryThreshold * 1.5)
Assert "Post-cluster recovery threshold: $effectiveThreshold" ($effectiveThreshold -eq 15)

# 2c: Outside cooldown
$lastClusterEnd = (Get-Date).AddSeconds(-400)  # 400s ago, outside 300s cooldown
$now = Get-Date
$inCooldown = ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval)
Assert "Outside cooldown (400s ago > 300s window)" (-not $inCooldown)

# ============================================================
# TEST GROUP 3: Code structure checks
# ============================================================
Write-Host "`n=== Code Structure ===" -ForegroundColor Cyan

$scriptPath = "$PSScriptRoot\..\WifiFix.ps1"
$content = Get-Content $scriptPath -Raw

Assert "Function exists: Update-ClusterState" ($content -match 'function Update-ClusterState')
Assert "Config exists: clusterGapThreshold" ($content -match '\$clusterGapThreshold')
Assert "Config exists: clusterHoldMultiplier" ($content -match '\$clusterHoldMultiplier')
Assert "Config exists: clusterCooldownInterval" ($content -match '\$clusterCooldownInterval')
Assert "State var: inCluster" ($content -match '\$inCluster')
Assert "State var: clusterDisconnects" ($content -match '\$clusterDisconnects')
Assert "State var: lastClusterEnd" ($content -match '\$lastClusterEnd')
Assert "Cluster column in CSV header" ($content -match 'Cluster')
Assert "Cluster display string exists" ($content -match 'CLUSTER')

# ============================================================
# TEST GROUP 4: Rapid burst sequence
# ============================================================
Write-Host "`n=== Rapid Burst Simulation ===" -ForegroundColor Cyan

# Simulate a common real-world pattern: calm -> burst -> calm
$inCluster = $false; $clusterDisconnects = 0; $lastClusterEnd = $null

# Calm period
Update-ClusterState 300
Assert "Calm 1: not in cluster" (-not $inCluster)
Update-ClusterState 250
Assert "Calm 2: not in cluster" (-not $inCluster)

# Burst starts
Update-ClusterState 40
Assert "Burst 1: in cluster" $inCluster
Update-ClusterState 15
Assert "Burst 2: in cluster, count=3" ($inCluster -and $clusterDisconnects -eq 3)
Update-ClusterState 8
Assert "Burst 3: in cluster, count=4" ($inCluster -and $clusterDisconnects -eq 4)
Update-ClusterState 25
Assert "Burst 4: in cluster, count=5" ($inCluster -and $clusterDisconnects -eq 5)

# Calm returns
Update-ClusterState 200
Assert "Calm returns: cluster ended" (-not $inCluster)
Assert "Calm returns: lastClusterEnd set" ($null -ne $lastClusterEnd)

# Another calm disconnect
Update-ClusterState 180
Assert "Second calm: still not in cluster" (-not $inCluster)
Assert "Second calm: clusterDisconnects = 1" ($clusterDisconnects -eq 1)

# ============================================================
# RESULTS
# ============================================================
Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
```

**Instructions for the agent:**
1. Complete all implementation tasks in this PRP first.
2. Copy `Update-ClusterState` from the modified `WifiFix.ps1` into the marked location in the test script.
3. Create the test file at `tests\test_03_cluster_detection.ps1`.
4. Run it: `powershell -File tests\test_03_cluster_detection.ps1`
5. All assertions must pass. Fix any failures before marking this PRP complete.

### Manual verification (cannot be automated)

1. **Live burst behavior:** Rapidly disconnect/reconnect primary. Confirm the script stays on secondary through the burst instead of ping-ponging.
2. **Extended hold visually confirmed:** During a cluster, observe the return timer is multiplied.

## Dependencies

- Requires PRP 01 and PRP 02 completed
- No other PRPs depend on this (PRP 04 and PRP 05 can be done in parallel)
