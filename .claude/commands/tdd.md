---
description: Enforce test-driven development workflow. Write Assert statements FIRST, then implement minimal code to pass. Uses project's custom Assert framework.
---

# TDD Command

This command invokes the **tdd-guide** agent to enforce test-driven development methodology using the project's custom Assert framework.

## What This Command Does

1. **Plan Assertions** - Define what to test first
2. **Write Failing Tests** - Create Assert statements (RED)
3. **Implement Minimal Code** - Write just enough to pass (GREEN)
4. **Refactor** - Improve code while keeping tests green (REFACTOR)

## When to Use

Use `/tdd` when:
- Implementing new features (write test file first)
- Adding new functions to WifiFix-Functions.ps1
- Fixing bugs (write assertion that reproduces bug first)
- Refactoring existing code
- Implementing a PRP

## TDD Cycle

```
RED -> GREEN -> REFACTOR -> REPEAT

RED:      Write Assert statements that will FAIL
GREEN:    Write minimal code to make them PASS
REFACTOR: Improve code, keep assertions passing
REPEAT:   Next feature/scenario
```

## Example Usage

```
User: /tdd I need a function to calculate weighted moving average of latencies

Agent (tdd-guide):
# TDD Session: Weighted Moving Average

## Step 1: Write Failing Tests (RED)

# tests/test_06_weighted_avg.ps1
. "$PSScriptRoot\..\WifiFix-Functions.ps1"
$script:failures = 0

Write-Host "`nTest Suite: Weighted Moving Average" -ForegroundColor Cyan

# Setup
$samples = @(10, 20, 30, 40, 50)

# Assertions
$result = Get-WeightedAverage $samples
Assert "Returns weighted average favoring recent" ($result -gt 30)
Assert "Handles single sample" ((Get-WeightedAverage @(42)) -eq 42)
Assert "Handles empty input" ($null -eq (Get-WeightedAverage @()))

# Report
if ($script:failures -gt 0) { exit 1 }

## Step 2: Run - Verify FAIL
powershell -File tests/test_06_weighted_avg.ps1
# FAIL: Get-WeightedAverage not found

## Step 3: Implement (GREEN)
# WifiFix-Functions.ps1
function Get-WeightedAverage($samples) { ... }

## Step 4: Run - Verify PASS
## Step 5: Refactor
## Step 6: Verify all other test suites still pass
```

## TDD Best Practices

**DO:**
- Write the Assert FIRST, before any implementation
- Run tests and verify they FAIL before implementing
- Write minimal code to make assertions pass
- Refactor only after tests are green
- Add edge cases (empty, null, boundary values)
- Reset `$script:` state between test sections

**DON'T:**
- Write implementation before tests
- Skip running tests after each change
- Write too much code at once
- Ignore failing assertions
- Test internal state (test function return values)

## Integration with Other Commands

- Use `/plan` first to understand what to build
- Use `/tdd` to implement with tests
- Use `/code-review` to review implementation
- Use `/verify` to run all checks
