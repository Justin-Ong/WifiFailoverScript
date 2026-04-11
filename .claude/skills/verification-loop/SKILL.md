---
name: verification-loop
description: Multi-phase verification loop covering syntax checking, test suites, static analysis, debug output audit, config consistency, and git diff review before commits.
---

# Verification Loop

## When to Activate

Use this skill when:
- Before committing changes
- After implementing a feature
- After refactoring
- Before creating a PR
- When something feels off

## Verification Phases

### Phase 1: Syntax Check
```powershell
# Parse all PowerShell files for syntax errors
$errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content 'WifiFix.ps1' -Raw), [ref]$errors
)
if ($errors) { Write-Host "Syntax errors found!" -ForegroundColor Red }

# Repeat for WifiFix-Functions.ps1 and test files
```

### Phase 2: Test Suites
```powershell
# Run all test suites
$failed = 0
Get-ChildItem tests/test_*.ps1 | ForEach-Object {
    powershell -File $_.FullName
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
```

### Phase 3: Static Analysis (if PSScriptAnalyzer available)
```powershell
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error
}
```

### Phase 4: Debug Output Audit
```powershell
# Check for debug Write-Host left in source (not tests)
Select-String -Path WifiFix.ps1,WifiFix-Functions.ps1 -Pattern 'Write-Host.*DEBUG|Write-Host.*TODO'
```

### Phase 5: Config Consistency
```powershell
# Verify config variables used in functions are defined in main script
# Check for orphaned variables from old features
```

### Phase 6: Git Diff Review
```powershell
git diff --stat
git diff HEAD
```

## Output Format

```
VERIFICATION: [PASS/FAIL]

Syntax:     [OK/FAIL]
Tests:      [5/5 suites passed, 65 assertions total]
Analyzer:   [OK/X issues] (or SKIPPED)
Debug:      [OK/X debug statements]
Config:     [OK/X orphaned vars]

Ready for commit: [YES/NO]
```

## Integration with Workflow

```
[Write Code] → /verify quick → [Fix issues] → /verify full → [Commit]
```

- `quick`: Syntax + Tests only
- `full`: All phases
- `pre-commit`: Syntax + Tests + Debug audit + Git status
