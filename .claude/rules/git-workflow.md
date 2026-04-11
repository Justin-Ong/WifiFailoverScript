# Git Workflow

## Commit Message Format

```
<type>: <description>

<optional body>
```

Types: feat, fix, refactor, docs, test, chore, perf

## Pull Request Workflow

When creating PRs:
1. Analyze full commit history (not just latest commit)
2. Use `git diff [base-branch]...HEAD` to see all changes
3. Draft comprehensive PR summary
4. Include test plan with TODOs
5. Push with `-u` flag if new branch

## Feature Implementation Workflow

1. **Plan First**
   - Use **planner** agent to create implementation plan
   - Write a PRP (Project Requirement Proposal) for non-trivial features
   - Identify dependencies and risks
   - Break down into phases

2. **TDD Approach**
   - Use **tdd-guide** agent
   - Write test assertions first (RED)
   - Implement to pass tests (GREEN)
   - Refactor (IMPROVE)
   - Add test to appropriate `tests/test_0X_*.ps1` file

3. **Code Review**
   - Use **code-reviewer** agent immediately after writing code
   - Address CRITICAL and HIGH issues
   - Fix MEDIUM issues when possible

4. **Commit & Push**
   - Detailed commit messages
   - Follow conventional commits format

## PRP Workflow

For non-trivial features, create a PRP in `PRPs/`:
1. Name: `XX-feature-name.md` (numbered sequentially)
2. Include: problem, design, implementation plan, test plan
3. Get confirmation before implementing
4. Create corresponding test file: `tests/test_0X_feature.ps1`
