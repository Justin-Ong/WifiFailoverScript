# Code Review

Comprehensive security and quality review of uncommitted changes:

1. Get changed files: git diff --name-only HEAD

2. For each changed file, check for:

**Security Issues (CRITICAL):**
- Hardcoded credentials or WiFi passwords
- Command injection risks (Invoke-Expression, string-built commands)
- Unvalidated adapter names passed to system cmdlets
- Missing -ErrorAction Stop on Set-NetIPInterface
- Sensitive network info in log output

**Code Quality (HIGH):**
- Functions > 60 lines
- Deep nesting > 4 levels
- Missing error handling in background runspaces
- Debug Write-Host statements left in code
- Direct state mutation instead of atomic snapshots
- Functions that should be in WifiFix-Functions.ps1 but aren't
- Missing tests for new functions
- Hardcoded values that should be config variables

**Best Practices (MEDIUM):**
- Approved-Verb naming for functions (Get-, Set-, Update-, Write-)
- $script: scope used for shared state in functions
- Color coding follows project convention
- CSV format changes are backward-compatible
- Config variables documented with comments

3. Generate report with:
   - Severity: CRITICAL, HIGH, MEDIUM, LOW
   - File location and line numbers
   - Issue description
   - Suggested fix

4. Block commit if CRITICAL or HIGH issues found

Never approve code with security vulnerabilities or missing error handling!
