# WifiFix - AI Agent Instructions

## Architecture Overview

This is a **PowerShell 5.1+ dual-adapter WiFi failover watchdog** with predictive analytics and adaptive cluster detection. Monitors two network adapters, predicts disconnection probability using empirical CDF analysis, and intelligently swaps adapter priority when degradation is detected.

### Core Stack
- **Language**: PowerShell 5.1+ (Windows; PowerShell 7+ for cross-platform)
- **Threading**: RunspacePool concurrent architecture (2 background probes + main loop)
- **Prediction Engine**: Empirical CDF model with recency-biased window
- **Cluster Detection**: State machine for rapid disconnect bursts
- **Persistence**: CSV disconnect log (`disconnect_log.csv`) with bounce filtering and adaptive thresholds
- **Testing**: Custom lightweight Assert framework (no Pester)

## Source of Truth

When instructions overlap, prioritize the more specific project rule documents in `.claude/rules/` (naming, testing, security, and workflow).
Keep this file as the high-level project map and update it when repository structure or critical filenames change.

## Critical Patterns

### 1. Atomic Snapshot Pattern (Cross-Thread State)
**MANDATORY for background thread communication**

```powershell
# Background thread writes entire snapshot as one object (atomic)
$state.Value = [PSCustomObject]@{
    Up      = $true
    Latency = 45
    Updated = Get-Date
}

# Main loop reads atomically (reference assignment, no lock needed)
$snapshot = $state.Value
if ($snapshot.Up) { ... }
```

Never mutate shared state in place (`$state.Value.Up = $true` is WRONG). Always replace the entire object.

### 2. RunspacePool Concurrency
Multiple background probes run in parallel via RunspacePool:

```powershell
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
$runspacePool.Open()

$ps = [PowerShell]::Create().AddScript($pingScript).AddArgument($adapter)
$ps.RunspacePool = $runspacePool
$handle = $ps.BeginInvoke()
```

Each adapter gets its own runspace; main loop polls results every 0.5s without blocking.

### 3. CDF Probability Model
Empirical cumulative distribution function for predicting disconnection probability:

```powershell
function Get-DisconnectProbability($elapsedSeconds) {
    # Count how many past disconnect intervals are <= elapsed time
    # Returns: count / total (empirical CDF value)
    # Recency-biased: uses last $predictionWindowSize intervals only
    # Returns: 0.0 if fewer than $minDataPoints intervals in window
}
```

Uses last N intervals (configurable via `$predictionWindowSize`), excludes bounces below adaptive floor.

### 4. Bounce Filter Pattern
Adaptive floor prevents noise from polluting the model:

```powershell
$floor = Get-MinStableInterval  # max($minStableIntervalFloor, median × 0.20)
if ($interval -ge $floor) {
    $intervals.Add($interval)   # Model-quality data only
}
# Bounces still logged to CSV but excluded from CDF model
```

### 5. Cluster Detection State Machine
Triggers failover on rapid disconnect bursts:

```powershell
# Disconnects at or below $clusterGapThreshold are part of the same burst
if ($interval -le $clusterGapThreshold) {
    $clusterDisconnects++
    if ($clusterDisconnects -ge 2) {
        $inCluster = $true
    }
}
```

## Development Workflows

### Setup & Run
```powershell
# Run main watchdog (elevated/admin privileges required)
powershell -ExecutionPolicy Bypass -File WifiFix.ps1

# Configure WiFi adapters and thresholds in config section at top of WifiFix.ps1
$primary = "Wi-Fi 2"
$secondary = "Wi-Fi 3"
$pingTarget = "192.168.50.1"
```

### Testing
```powershell
# Run individual test suite
powershell -File tests/test_01_data_pipeline.ps1

# Run all tests
Get-ChildItem tests/test_*.ps1 | ForEach-Object { 
    Write-Host "Running: $($_.Name)" -ForegroundColor Cyan
    powershell -File $_.FullName 
}
```

**Test Framework:** Custom Assert function (see `testing.md` for details). Tests dot-source `WifiFix-Functions.ps1` and validate functions in isolation.

### Debugging Tips
1. Check `$staleProbeThreshold` - probes older than 10s are treated as DOWN
2. Check `$minDataPoints` - CDF returns 0.0 with fewer than 3 intervals
3. Check `Get-MinStableInterval` - bounces below floor are excluded from model
4. For probe troubleshooting, add temporary `Write-Host` output in the ping runspace loop, then remove it after diagnosis

## Project-Specific Conventions

### 1. Naming Conventions (CRITICAL)
Follow PowerShell community standards:
- **Functions**: `PascalCase` with Approved-Verb prefix: `Get-DisconnectProbability`, `Update-ClusterState`
- **Variables**: `camelCase` for local, `PascalCase` for parameters
- **Script-scope**: `$script:varName` for explicit scoping of shared state
- **Constants/Config**: `camelCase` at script top: `$swapProbThreshold`, `$maxHoldTime`
- **Booleans**: Prefix with `$is`, `$has`, `$in`, `$can`: `$inCluster`, `$isDegraded`

### 2. File Organization
```
WifiFix/
├── WifiFix.ps1                 # Main orchestration, state, and loop
├── WifiFix-Functions.ps1       # Shared functions (dot-sourced by main + tests)
├── analyse_logs.ps1            # Disconnect log analysis utility
├── README.md                   # User-facing setup and usage guide
├── tests/
│   ├── test_01_data_pipeline.ps1      # CSV loading, bounce filter
│   ├── test_02_cdf_engine.ps1         # Probability calculation
│   ├── test_03_cluster_detection.ps1  # State machine
│   ├── test_04_degradation.ps1        # Threshold logic
│   └── test_05_disconnect_log.ps1     # Log writing, integration
├── PRPs/                       # Project Requirement Proposals (feature specs)
└── disconnect_log.csv          # Persistent disconnect log
```

(`.claude/`, `.github/`, and workshop subfolders omitted for brevity.)

Shared functions go in `WifiFix-Functions.ps1` and are dot-sourced by both main script and tests. Main script handles orchestration, state management, and the 0.5s loop.

### 3. Error Handling (MANDATORY)
Always wrap risky operations in try/catch, especially in background threads:

```powershell
# Background ping loop - must NEVER crash
try {
    $result = ping.exe -S $adapterIP $target -n 1 -w $timeout
    $state.Value = [PSCustomObject]@{ Up = $true; Latency = $ms; Updated = Get-Date }
} catch {
    # Stale data treated as DOWN, not error
    $state.Value = [PSCustomObject]@{ Up = $false; Latency = 0; Updated = Get-Date }
}
```

### 4. Console Output (Consistent Color Coding)
```powershell
Write-Host "Success message" -ForegroundColor Green      # Healthy, success
Write-Host "Failed operation" -ForegroundColor Red       # Failed, down
Write-Host "Warning: degradation" -ForegroundColor Yellow # Warnings
Write-Host "Predicted action" -ForegroundColor Blue      # Predictive decisions
Write-Host "FAILOVER EVENT" -ForegroundColor Magenta     # Failover triggers
Write-Host "Info: probe latency" -ForegroundColor DarkGray # Informational
```

### 5. CSV Disconnect Log Format
```
Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster
2026-04-09 14:30:15,Wi-Fi 2,342,0.72,32.5,3.12,False,False
```
- Index-based field parsing (not header-based) for backward compatibility
- New columns always appended at end
- Corrupt lines skipped silently during load

## Key Integration Points

### Predictive Failover Decision
1. **CDF Engine** calculates disconnect probability from historical intervals
2. **Degradation Detector** compares relative jitter against baseline
3. **Cluster Detection** identifies rapid disconnect bursts
4. **Failover Logic** combines signals: `(Prob > threshold) OR (Jitter > 2σ) OR (Cluster)`

### Probe Staleness Guard
Stale probe data (>10s old) treated as DOWN, not as cached success:
```powershell
$age = (Get-Date) - $snapshot.Updated
if ($age.TotalSeconds -gt $staleProbeThreshold) {
    $isUp = $false  # Conservative: assume down when stale
}
```

### Main Loop Timing
- Main loop polls state every 0.5s (tight responsiveness)
- Background pings run in parallel (non-blocking)
- CSV logging happens after decision (once per disconnect)
- Log trimming amortized every 50 disconnects

## Common Pitfalls

1. **DON'T mutate shared state directly** - Replace entire snapshot atomically
   ```powershell
   # WRONG:
   $state.Value.Up = $true
   
   # CORRECT:
   $state.Value = [PSCustomObject]@{ Up = $true; Latency = 45; Updated = Get-Date }
   ```

2. **DON'T use old variable names** - Config uses new naming: `$predictionWindowSize`, not `$emaInterval`

3. **DON'T hardcode adapter names or IPs** - All configurable at script top

4. **DON'T crash background threads** - Always wrap ping logic in try/catch

5. **DON'T assume data exists** - Check CSV row counts before indexing: `if ($intervals.Count -lt $minDataPoints) { return 0.0 }`

6. **DON'T treat stale data as success** - Age check: `if ($age.TotalSeconds -gt 10) { treat as DOWN }`

7. **DON'T set `$predictionBaseTime` outside the main loop** - Log loading must not anchor prediction timing; only live unhealthy→healthy transitions should.

## Test File Organization

| File | Feature Area | Validates |
|------|-------------|-----------|
| `test_01_data_pipeline.ps1` | CSV loading, bounce filter | Data ingestion, floor calculation |
| `test_02_cdf_engine.ps1` | Probability calculation | CDF logic, percentiles |
| `test_03_cluster_detection.ps1` | Cluster state machine | State transitions, thresholds |
| `test_04_degradation.ps1` | Link degradation | Relative jitter, baseline |
| `test_05_disconnect_log.ps1` | Log writing, integration | CSV format, trimming |

Create new test files matching PRP numbers: `test_0N_feature.ps1`

## Agent Orchestration

### Immediate Agent Usage
- **Complex feature requests** → Use `planner` agent for implementation plan
- **Code just written** → Use `code-reviewer` agent for quality/security review
- **Bug fix or new feature** → Use `tdd-guide` agent (enforce write-tests-first)
- **New subsystem** → Use `architect` agent for system design
- **Dead code cleanup** → Use `refactor-cleaner` agent
- **Documentation updates** → Use `doc-updater` agent

### Testing Workflows
- Use `tdd-guide` agent PROACTIVELY for any new feature or fix
- Enforce write-tests-first: Assert statements → failing test → minimal implementation → passing test

## File Reference

- **Main Script**: `WifiFix.ps1` (orchestration, main loop, state management)
- **Shared Functions**: `WifiFix-Functions.ps1` (CDF engine, cluster detection, degradation logic)
- **Test Suite**: `tests/test_0*.ps1` (numbered by feature area)
- **Requirements**: `PRPs/` (Project Requirement Proposals with design and test plans)
- **Disconnect Log**: `disconnect_log.csv` (persistent history for analytics)
- **Utilities**: `analyse_logs.ps1` (offline log inspection and trend analysis)
- **Documentation**: `README.md`
