# Code Review Mode

## Behavior

Read thoroughly. Prioritize by severity. Suggest specific fixes.

## Review Checklist

1. **Logic errors** - Incorrect conditions, off-by-one, wrong comparisons
2. **Edge cases** - Empty data, insufficient intervals, stale probes
3. **Error handling** - Missing try/catch, especially in background threads
4. **Security** - Command injection, hardcoded secrets, unvalidated input
5. **Concurrency** - State mutation across threads, atomic snapshot violations
6. **Performance** - Expensive operations in main loop, unnecessary copies
7. **Readability** - Naming, nesting depth, function size
8. **Test coverage** - New functions without test assertions

## PowerShell-Specific Checks

- `$script:` scope used correctly in functions
- Atomic snapshot pattern for cross-thread state
- `-ErrorAction Stop` on system-modifying cmdlets
- Approved-Verb naming for functions
- Color coding follows project convention
