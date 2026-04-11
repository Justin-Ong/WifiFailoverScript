---
description: Chain multiple agents for complex WifiFix tasks. Workflows: feature (planner→tdd→review→security), bugfix, refactor, security, design.
---

# Orchestrate Command

Sequential agent workflow for complex WifiFix tasks.

## Usage

`/orchestrate [workflow-type] [task-description]`

## Workflow Types

### feature
Full feature implementation with PRP and TDD:
```
planner -> tdd-guide -> code-reviewer -> security-reviewer
```

### bugfix
Bug investigation and fix:
```
tdd-guide -> code-reviewer
```

### refactor
Safe refactoring with tests:
```
refactor-cleaner -> code-reviewer -> tdd-guide
```

### security
Security-focused review and hardening:
```
security-reviewer -> code-reviewer
```

### design
Architecture decision for new subsystem:
```
architect -> planner -> code-reviewer
```

## Execution Pattern

For each agent in the workflow:

1. **Invoke agent** with context from previous agent
2. **Collect output** as a structured handoff note
3. **Pass to next agent** in chain
4. **Aggregate results** into a final report

## Handoff Document Format

Between agents, create a handoff block:

```markdown
## HANDOFF: [previous-agent] -> [next-agent]

### Context
[Summary of what was done]

### Findings
[Key discoveries or decisions]

### Files Modified
[List of files touched]

### Open Questions
[Unresolved items for next agent]

### Recommendations
[Suggested next steps]
```

## Example: Feature Workflow

```
/orchestrate feature "Add latency spike early-warning"
```

Executes:

1. **Planner Agent**
   - Reads WifiFix.ps1 and WifiFix-Functions.ps1 for context
   - Restates requirements and identifies concurrency/state risks
   - Drafts PRP outline and test plan (TDD-first)
   - Waits for confirmation
   - Output: `HANDOFF: planner -> tdd-guide`

2. **TDD Guide Agent**
   - Reads planner handoff
   - Writes Assert statements in correct `tests/test_0N_*.ps1` file (RED)
   - Runs tests – verifies they fail
   - Implements minimal code in WifiFix-Functions.ps1 (GREEN)
   - Runs tests – verifies they pass
   - Output: `HANDOFF: tdd-guide -> code-reviewer`

3. **Code Reviewer Agent**
   - Reviews implementation against project checklist
   - Checks atomic snapshots, $script: scope, error handling, naming
   - Flags CRITICAL/HIGH/MEDIUM issues
   - Output: `HANDOFF: code-reviewer -> security-reviewer`

4. **Security Reviewer Agent**
   - Checks for hardcoded IPs/credentials, command injection, log leaks
   - Verifies adapter validation, -ErrorAction Stop on system cmdlets
   - Final approval or block
   - Output: Final Report

## Final Report Format

```
ORCHESTRATION REPORT
====================
Workflow: [type]
Task: [description]
Agents: [chain]

SUMMARY
-------
[One paragraph summary]

AGENT OUTPUTS
-------------
[Agent]: [summary of findings]

FILES CHANGED
-------------
[file]: [what changed]

RESULT
------
APPROVED / BLOCKED: [reason if blocked]
```

## Notes

- The planner agent **always waits for your explicit confirmation** before any code is written
- CRITICAL or HIGH issues from code-reviewer or security-reviewer **block the workflow**
- Intermediate handoff documents are temporary – discard after orchestration completes
