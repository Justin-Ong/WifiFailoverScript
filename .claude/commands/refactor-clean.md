# Refactor Clean

Safely identify and remove dead code with test verification:

1. Run dead code analysis:
   - Grep for all function definitions in .ps1 files
   - Grep for all $script: and config variable assignments
   - Cross-reference: find definitions with no usage
   - Check for remnants of replaced features (old EMA model, etc.)

2. Generate report categorized by risk:
   - SAFE: Commented-out code, clearly unused variables
   - CAUTION: Functions used in specific code paths
   - DANGER: Config variables, state variables, cross-thread state

3. Propose safe deletions only

4. Before each deletion:
   - Run all 5 test suites
   - Verify tests pass
   - Apply change
   - Re-run tests
   - Rollback if tests fail

5. For function extraction (moving logic to WifiFix-Functions.ps1):
   - Extract function
   - Add $script: scope for state access
   - Write tests
   - Verify existing tests still pass

6. Show summary of cleaned items

Never delete code without running all test suites first!
