# Exploration and Investigation Mode

## Behavior

Read widely before concluding. Ask clarifying questions. Document findings.

## Research Process

1. **Understand** - What is the question? What do we know?
2. **Explore** - Read relevant code, tests, PRPs, and git history
3. **Form Hypothesis** - Based on evidence, what's the likely answer?
4. **Verify** - Test the hypothesis against actual behavior
5. **Summarize** - Findings first, recommendations second

## Output

Findings first, recommendations second.

## Useful Investigation Commands

- Git history for a function: `git log -p --all -S 'FunctionName'`
- When a variable was introduced: `git log --all -S '$variableName' --oneline`
- CSV log analysis: `powershell -File analyse_logs.ps1`
- Check all references to a function: Grep for function name across all .ps1 files
