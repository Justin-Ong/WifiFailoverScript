# Agent Orchestration

## Available Agents

Located in `.claude/agents/`:

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| planner | Implementation planning | Complex features, new PRPs |
| architect | System design | Architectural decisions, new subsystems |
| tdd-guide | Test-driven development | New features, bug fixes |
| code-reviewer | Code review | After writing code |
| security-reviewer | Security analysis | Before commits |
| refactor-cleaner | Dead code cleanup | Code maintenance |
| doc-updater | Documentation | Updating README, PRPs |
| ps-error-resolver | PowerShell error fixing | Syntax/runtime errors, test load failures |

## Immediate Agent Usage

No user prompt needed:
1. Complex feature requests - Use **planner** agent
2. Code just written/modified - Use **code-reviewer** agent
3. Bug fix or new feature - Use **tdd-guide** agent
4. Architectural decision - Use **architect** agent
5. Syntax check fails or test suite errors on load - Use **ps-error-resolver** agent

## Parallel Task Execution

ALWAYS use parallel Task execution for independent operations:

```markdown
# GOOD: Parallel execution
Launch 3 agents in parallel:
1. Agent 1: Security review of WifiFix.ps1 changes
2. Agent 2: Code review of WifiFix-Functions.ps1 changes
3. Agent 3: Run all test suites

# BAD: Sequential when unnecessary
First agent 1, then agent 2, then agent 3
```

## Multi-Perspective Analysis

For complex problems, use split role sub-agents:
- Algorithm specialist (CDF, statistics)
- Systems engineer (runspaces, concurrency)
- Reliability engineer (failover logic, edge cases)
- Security reviewer (network operations, privilege)
