---
description: Restate requirements, assess risks, and create step-by-step implementation plan. WAIT for user CONFIRM before touching any code.
---

# Plan Command

This command invokes the **planner** agent to create a comprehensive implementation plan before writing any code.

## What This Command Does

1. **Restate Requirements** - Clarify what needs to be built
2. **Identify Risks** - Surface potential issues (concurrency, state, performance)
3. **Create Step Plan** - Break down implementation into phases
4. **Draft PRP** - Outline the Project Requirement Proposal
5. **Wait for Confirmation** - MUST receive user approval before proceeding

## When to Use

Use `/plan` when:
- Starting a new feature for WifiFix
- Making changes to the prediction engine or cluster detection
- Working on complex refactoring
- Adding new config variables or changing existing behavior
- Modifying background runspace behavior

## How It Works

The planner agent will:

1. **Analyze the request** and restate requirements
2. **Review existing code** in WifiFix.ps1 and WifiFix-Functions.ps1
3. **Break down into phases** with specific, actionable steps
4. **Identify risks** (concurrency, state corruption, performance)
5. **Draft a PRP** for the feature
6. **Plan test file** with assertions to write first (TDD)
7. **Present the plan** and WAIT for explicit confirmation

## Important Notes

**CRITICAL**: The planner agent will **NOT** write any code until you explicitly confirm the plan.

If you want changes, respond with:
- "modify: [your changes]"
- "different approach: [alternative]"
- "skip phase 2 and do phase 3 first"

## Integration with Other Commands

After planning:
- Use `/tdd` to implement with test-driven development
- Use `/code-review` to review completed implementation
- Use `/verify` to run all checks
