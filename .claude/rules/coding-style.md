# Coding Style

## PowerShell Conventions (CRITICAL)

Follow PowerShell community standards and existing project conventions.

### Naming

- **Functions**: PascalCase with Approved-Verb prefix: `Get-DisconnectProbability`, `Update-ClusterState`
- **Variables**: camelCase for local, PascalCase for parameters: `$elapsedSeconds`, `$PingTarget`
- **Script-scope variables**: `$script:varName` for explicit scoping in shared state
- **Constants/Config**: camelCase at script top: `$swapProbThreshold`, `$maxHoldTime`
- **Booleans**: Prefix with `$is`, `$has`, `$in`, or `$can`: `$inCluster`, `$isDegraded`

### Atomic Snapshots Pattern (CRITICAL)

ALWAYS use immutable snapshot replacement for cross-thread state:

```powershell
# WRONG: Mutating shared state in place
$state.Value.Up = $true
$state.Value.Latency = 45

# CORRECT: Replace entire snapshot atomically
$state.Value = [PSCustomObject]@{ Up = $true; Latency = 45; Updated = Get-Date }
```

Main loop reads via: `$snapshot = $state.Value` (atomic reference assignment, no lock needed).

## File Organization

- **Shared functions** in dedicated file (`WifiFix-Functions.ps1`) dot-sourced by main script and tests
- **Main script** (`WifiFix.ps1`) handles orchestration, state, and the main loop
- **Tests** in `tests/` directory, numbered by feature area
- **PRPs** (requirement proposals) in `PRPs/` directory

## Error Handling

ALWAYS wrap risky operations in try/catch, especially in background threads:

```powershell
# Background ping loop - must never crash
try {
    $result = ping.exe -S $adapterIP $target -n 1 -w $timeout
    $state.Value = [PSCustomObject]@{ Up = $true; Latency = $ms; Updated = Get-Date }
} catch {
    $state.Value = [PSCustomObject]@{ Up = $false; Latency = 0; Updated = Get-Date }
}
```

## Graceful Degradation

- CSV parse failures: skip line, continue
- Metric setting failures: log error, don't exit
- Stale probe data: treat as DOWN, not error
- Insufficient data: return safe defaults (0.0 probability, $null percentile)

## Code Quality Checklist

Before marking work complete:
- [ ] Functions use Approved-Verb naming (`Get-`, `Set-`, `Update-`, `Write-`)
- [ ] Functions are focused (<60 lines)
- [ ] No deep nesting (>4 levels)
- [ ] Proper error handling (try/catch in loops and background threads)
- [ ] No hardcoded adapter names or IPs (use config variables)
- [ ] Atomic snapshot pattern for cross-thread state
- [ ] `$script:` prefix used for shared state in functions
- [ ] Write-Host uses appropriate color coding
