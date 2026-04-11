---
name: tdd-workflow
description: Test-driven development workflow using custom Assert framework for PowerShell, with test templates, patterns for unit/state-machine/edge-case tests, and running instructions.
---

# TDD Workflow for PowerShell (Custom Assert Framework)

## When to Activate

Use this skill when:
- Writing new features or fixing bugs
- Adding functions to WifiFix-Functions.ps1
- Implementing a PRP
- Refactoring code that needs test verification

## Core Principles

1. **RED** - Write failing Assert statements first
2. **GREEN** - Write minimal code to pass
3. **REFACTOR** - Improve while keeping assertions green
4. **REPEAT** - Next scenario

## Test File Template

```powershell
# tests/test_XX_feature_name.ps1

# Dot-source shared functions
. "$PSScriptRoot\..\WifiFix-Functions.ps1"

$script:failures = 0

function Assert($name, $condition) {
    if ($condition) {
        Write-Host "  PASS: $name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $name" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host "`n=== Test Suite: Feature Name ===" -ForegroundColor Cyan

# --- Section 1: Basic Functionality ---
Write-Host "`nSection 1: Basic Functionality" -ForegroundColor White

# Setup (reset state before each section)
$script:intervals = [System.Collections.Generic.List[double]]::new()
$script:inCluster = $false
# ... other state resets

# Test
$result = Get-SomeFunction $input
Assert "Returns expected value" ($result -eq $expected)

# --- Section 2: Edge Cases ---
Write-Host "`nSection 2: Edge Cases" -ForegroundColor White

# Setup (clean state)
$script:intervals = [System.Collections.Generic.List[double]]::new()

# Test
Assert "Handles empty input" ($null -eq (Get-SomeFunction @()))

# --- Section 3: Code Structure ---
Write-Host "`nSection 3: Code Structure Validation" -ForegroundColor White

$content = Get-Content "$PSScriptRoot\..\WifiFix.ps1" -Raw
Assert "Config variable exists" ($content -match '\$newConfigVar')

# --- Report ---
Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) test(s) FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests passed" -ForegroundColor Green
}
```

## Testing Patterns

### Unit Test: Pure Function
```powershell
$script:intervals = [System.Collections.Generic.List[double]]::new()
@(100, 200, 300, 400, 500) | ForEach-Object { $script:intervals.Add($_) }
$script:minDataPoints = 3
$script:predictionWindowSize = 20

$prob = Get-DisconnectProbability 300
Assert "CDF at 300 with 5 intervals" ([Math]::Abs($prob - 0.6) -lt 0.001)
```

### State Machine Test: Sequence of Events
```powershell
$script:inCluster = $false
$script:clusterDisconnects = 0
$script:clusterGapThreshold = 120
$script:lastClusterEnd = $null

Update-ClusterState 60    # Short gap
Assert "Not yet cluster (count=1)" ($script:inCluster -eq $false)

Update-ClusterState 30    # Another short gap
Assert "Cluster triggered (count>=2)" ($script:inCluster -eq $true)

Update-ClusterState 200   # Long gap
Assert "Cluster ended" ($script:inCluster -eq $false)
```

### Edge Case Test: Boundary Values
```powershell
# Exactly at threshold
$script:intervals = [System.Collections.Generic.List[double]]::new()
@(100, 100, 100) | ForEach-Object { $script:intervals.Add($_) }
$prob = Get-DisconnectProbability 100
Assert "At exact boundary, probability includes equal values" ($prob -eq 1.0)

# Just below minimum data
$script:intervals = [System.Collections.Generic.List[double]]::new()
@(100, 200) | ForEach-Object { $script:intervals.Add($_) }
$prob = Get-DisconnectProbability 150
Assert "Below minDataPoints returns 0" ($prob -eq 0.0)
```

### Code Structure Test: Verify Cleanup
```powershell
$content = Get-Content "$PSScriptRoot\..\WifiFix.ps1" -Raw
Assert "No orphaned EMA code" ($content -notmatch '\$emaInterval')
Assert "No orphaned EMA alpha" ($content -notmatch '\$emaAlpha')
Assert "New config var present" ($content -match '\$predictionWindowSize')
```

## Common Mistakes to Avoid

1. **Forgetting state reset** between test sections
2. **Testing internal state** instead of function return values
3. **Float comparison** without tolerance (use `[Math]::Abs($a - $b) -lt 0.001`)
4. **Dependent tests** that rely on state from previous sections
5. **Missing edge cases**: empty, null, insufficient data, boundary values
6. **Not running all suites** after changes (a fix in one area can break another)

## Running Tests

```powershell
# Single suite
powershell -File tests/test_02_cdf_engine.ps1

# All suites with summary
$failed = 0
Get-ChildItem tests/test_*.ps1 | ForEach-Object {
    Write-Host "`nRunning $($_.Name)..." -ForegroundColor Cyan
    powershell -File $_.FullName
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
Write-Host "`n$failed suite(s) had failures" -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
```
