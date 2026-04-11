# Verification Command

Run comprehensive verification on current codebase state.

## Instructions

Execute verification in this exact order:

1. **Syntax Check**
   - Parse all .ps1 files for syntax errors
   - `powershell -Command "& { $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content 'WifiFix.ps1' -Raw), [ref]$null) }"`
   - If it fails, report errors and STOP

2. **PSScriptAnalyzer** (if available)
   - Run `Invoke-ScriptAnalyzer -Path . -Recurse` if module is installed
   - Report warnings and errors

3. **Test Suite**
   - Run all test files: `Get-ChildItem tests/test_*.ps1`
   - Report pass/fail count per suite
   - Report total assertions passed/failed

4. **Debug Output Audit**
   - Search for debug Write-Host statements in source files (not tests)
   - Report locations

5. **Config Consistency**
   - Verify all config variables referenced in functions exist in WifiFix.ps1
   - Check for orphaned variables from old features

6. **Git Status**
   - Show uncommitted changes
   - Show files modified since last commit

## Output

Produce a concise verification report:

```
VERIFICATION: [PASS/FAIL]

Syntax:   [OK/FAIL]
Analyzer: [OK/X issues] (or SKIPPED if not installed)
Tests:    [X/Y suites passed, Z assertions total]
Debug:    [OK/X debug statements]
Config:   [OK/X orphaned vars]

Ready for commit: [YES/NO]
```

If any critical issues, list them with fix suggestions.

## Arguments

$ARGUMENTS can be:
- `quick` - Only syntax + tests
- `full` - All checks (default)
- `pre-commit` - Checks relevant for commits
