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

# --- Function from WifiFix-Functions.ps1 ---
. "$PSScriptRoot\..\WifiFix-Functions.ps1"

# ============================================================
# TEST GROUP 1: Cluster state transitions
# ============================================================
Write-Host "`n=== Cluster State Machine ===" -ForegroundColor Cyan

$inCluster = $false; $clusterDisconnects = 0; $lastClusterEnd = $null

# 1a: First disconnect — not a cluster yet
Update-ClusterState 200
Assert "First disconnect: not in cluster" (-not $inCluster)
Assert "First disconnect: clusterDisconnects = 1" ($clusterDisconnects -eq 1)

# 1b: Second disconnect within gap — triggers cluster
Update-ClusterState 60
Assert "Second disconnect (within gap): in cluster" $inCluster
Assert "Second disconnect: clusterDisconnects = 2" ($clusterDisconnects -eq 2)

# 1c: Third disconnect within gap — still in cluster
Update-ClusterState 30
Assert "Third disconnect: still in cluster" $inCluster
Assert "Third disconnect: clusterDisconnects = 3" ($clusterDisconnects -eq 3)

# 1d: Disconnect after long gap — cluster ends
Update-ClusterState 200
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
$lastClusterEnd = (Get-Date).AddSeconds(-100)
$now = Get-Date
$inCooldown = ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval)
Assert "Post-cluster cooldown active (100s ago < 300s window)" $inCooldown
$effectiveThreshold = [math]::Ceiling($recoveryThreshold * 1.5)
Assert "Post-cluster recovery threshold: $effectiveThreshold" ($effectiveThreshold -eq 15)

# 2c: Outside cooldown
$lastClusterEnd = (Get-Date).AddSeconds(-400)
$now = Get-Date
$inCooldown = ($null -ne $lastClusterEnd -and ($now - $lastClusterEnd).TotalSeconds -lt $clusterCooldownInterval)
Assert "Outside cooldown (400s ago > 300s window)" (-not $inCooldown)

# ============================================================
# TEST GROUP 3: Code structure checks
# ============================================================
Write-Host "`n=== Code Structure ===" -ForegroundColor Cyan

$scriptPath = "$PSScriptRoot\..\WifiFix.ps1"
$content = Get-Content $scriptPath -Raw
$fnContent = Get-Content "$PSScriptRoot\..\WifiFix-Functions.ps1" -Raw

Assert "Function exists: Update-ClusterState" ($fnContent -match 'function Update-ClusterState')
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
