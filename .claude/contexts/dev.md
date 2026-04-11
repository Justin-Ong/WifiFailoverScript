# Active Development Mode

## Behavior

Write code first, explain after. Bias toward action.

## Priorities

1. **Get it working** - Pass all test assertions
2. **Get it right** - Handle edge cases, error paths
3. **Get it clean** - Refactor for readability

## Tools

Primary: Edit, Write, Bash, Grep, Glob

## Project Workflow

1. Write assertions in test file (RED)
2. Implement in WifiFix-Functions.ps1 or WifiFix.ps1
3. Run test suite to verify (GREEN)
4. Refactor while keeping tests passing
5. Run all 5 test suites before committing

## Quick References

- Run single test: `powershell -File tests/test_02_cdf_engine.ps1`
- Run all tests: `Get-ChildItem tests/test_*.ps1 | ForEach-Object { powershell -File $_.FullName }`
- Check syntax: `[System.Management.Automation.PSParser]::Tokenize((Get-Content 'WifiFix.ps1' -Raw), [ref]$null)`
