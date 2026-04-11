---
name: coding-standards
description: PowerShell coding standards including naming conventions, file organization, error handling, console output color scheme, and data structure best practices.
---

# PowerShell Coding Standards

## When to Activate

Use this skill when:
- Writing new PowerShell code
- Reviewing code for standards compliance
- Refactoring existing code
- Onboarding to the project conventions

## Naming Conventions

### Functions
- **Pattern**: `Approved-Verb` + `Noun` in PascalCase
- **Examples**: `Get-DisconnectProbability`, `Update-ClusterState`, `Write-DisconnectLog`
- **Common verbs**: Get, Set, Update, Write, Test, Switch

### Variables
- **Local**: camelCase - `$elapsedSeconds`, `$currentLatency`
- **Config/Parameters**: camelCase at script top - `$swapProbThreshold`, `$maxHoldTime`
- **Script-scope shared**: `$script:intervals`, `$script:inCluster`
- **Booleans**: Prefix with `$is`, `$in`, `$has`, `$can` - `$inCluster`, `$isDegraded`

### Files
- Main script: `WifiFix.ps1`
- Shared functions: `WifiFix-Functions.ps1`
- Tests: `tests/test_XX_feature_name.ps1` (numbered by PRP)
- PRPs: `PRPs/XX-feature-name.md`

## Code Organization

### WifiFix-Functions.ps1 (Shared Functions)
- Pure-ish functions that can be tested independently
- Access shared state via `$script:` scope (set by test setup or main script)
- No side effects beyond `$script:` state updates
- No Write-Host output (leave that to callers)

### WifiFix.ps1 (Main Script)
- Configuration variables at the top
- Helper functions specific to main script (Switch-To, Set-AdapterPriority)
- Background runspace setup
- Main loop orchestration
- Console output and formatting

## Error Handling

### In Background Threads (CRITICAL)
```powershell
# Must NEVER crash - wrap everything in try/catch
try {
    # Ping and update state
} catch {
    $state.Value = [PSCustomObject]@{ Up = $false; Latency = 0; Updated = Get-Date }
}
```

### In System Commands
```powershell
try {
    Set-NetIPInterface -InterfaceAlias $adapter -InterfaceMetric $metric -ErrorAction Stop
} catch {
    Write-Host "Failed: $_" -ForegroundColor Red
    return $null
}
```

### In Data Parsing
```powershell
# Skip corrupt data, don't crash
$val = 0.0
if (-not [double]::TryParse($str, [ref]$val)) { continue }
```

## Console Output Standards

### Color Scheme
| Color | Meaning | Example |
|-------|---------|---------|
| Green | Healthy, success | "Primary UP (45ms)" |
| Red | Failed, down | "Primary DOWN" |
| Yellow | Warning, degradation | "Jitter elevated: 32ms" |
| Blue | Predictive action | "CDF 72% - predictive swap" |
| Magenta | Failover event | "SWITCHING to Wi-Fi 3" |
| DarkGray | Informational | "Loaded 15 intervals from log" |

### Formatting
- Timestamps: `HH:mm:ss` for console, `yyyy-MM-dd HH:mm:ss` for CSV
- Latency: Integer milliseconds, no decimals ("45ms")
- Probabilities: Percentage ("72%")
- Durations: Seconds with unit ("312s")

## Data Structure Conventions

### Use Generic Lists (Not Arrays)
```powershell
# GOOD: Efficient add/remove
$intervals = [System.Collections.Generic.List[double]]::new()
$intervals.Add(300.0)

# BAD: Creates new array on every add
$intervals += 300.0
```

### Use PSCustomObject for Structured Data
```powershell
$result = [PSCustomObject]@{
    Jitter          = $jitter
    Trend           = $slope
    Degraded        = ($jitter -gt $threshold -or $slope -gt $trendThreshold)
    JitterThreshold = $threshold
}
```

## Configuration Best Practices

- All thresholds as named variables at script top
- Group related config (Core, Prediction, Cluster, Degradation)
- Comment each variable with purpose and units
- No magic numbers in logic - always reference config variable
