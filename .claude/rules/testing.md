# Testing Requirements

## Test Framework

This project uses a **custom lightweight Assert framework** (not Pester):

```powershell
function Assert($name, $condition) {
    if ($condition) {
        Write-Host "  PASS: $name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $name" -ForegroundColor Red
        $script:failures++
    }
}
```

Tests are standalone `.ps1` scripts in `tests/` that dot-source `WifiFix-Functions.ps1`.

## Test File Convention

Tests are numbered by feature/PRP area:

| File | Feature Area |
|------|-------------|
| `test_01_data_pipeline.ps1` | CSV loading, bounce filter, bootstrap |
| `test_02_cdf_engine.ps1` | Probability calculation, percentiles |
| `test_03_cluster_detection.ps1` | Cluster state machine, thresholds |
| `test_04_degradation.ps1` | Relative jitter thresholds, baseline |
| `test_05_disconnect_log.ps1` | Log writing, trimming, integration |

New features get a new numbered test file matching their PRP number.

## Test-Driven Development

MANDATORY workflow:
1. Write Assert statements first (RED)
2. Run test - assertions should FAIL
3. Write minimal implementation (GREEN)
4. Run test - assertions should PASS
5. Refactor (IMPROVE)

## Test Patterns

### Unit Tests on Functions
```powershell
# Known input → verify output
$script:intervals = [System.Collections.Generic.List[double]]::new()
@(100, 200, 300, 400, 500) | ForEach-Object { $script:intervals.Add($_) }
$prob = Get-DisconnectProbability 300
Assert "CDF at median returns 0.6" ($prob -eq 0.6)
```

### State Machine Tests
```powershell
# Simulate event sequences, verify transitions
$script:inCluster = $false
$script:clusterDisconnects = 0
Update-ClusterState 60   # short gap
Update-ClusterState 30   # another short gap
Assert "Cluster triggered after 2 rapid disconnects" ($script:inCluster -eq $true)
```

### Code Structure Validation
```powershell
# Verify orphaned code is removed, config vars exist
$content = Get-Content WifiFix.ps1 -Raw
Assert "No orphaned EMA variable" ($content -notmatch '\$emaInterval')
Assert "predictionWindowSize defined" ($content -match '\$predictionWindowSize')
```

## Running Tests

```powershell
# Run individual test suite
powershell -File tests/test_01_data_pipeline.ps1

# Run all tests
Get-ChildItem tests/test_*.ps1 | ForEach-Object { powershell -File $_.FullName }
```

## Agent Support

- **tdd-guide** - Use PROACTIVELY for new features, enforces write-tests-first
