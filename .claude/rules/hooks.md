# Hooks System

## Hook Types

- **PreToolUse**: Before tool execution (validation, parameter modification)
- **PostToolUse**: After tool execution (checks, formatting)
- **Stop**: When session ends (final verification)

## Current Hooks (in .claude/hooks.json)

### PreToolUse
- **doc blocker**: Blocks creation of unnecessary .md/.txt files outside PRPs/ and docs/
- **push reminder**: Reminds to review changes and run all 5 test suites before `git push`

### PostToolUse
- **PR helper**: Logs the PR URL and a ready-to-run `gh pr review` command after `gh pr create`
- **Write-Host warning**: Warns about debug Write-Host statements left in edited files

### Stop
- **debug audit**: Scans modified `.ps1` files for debug `Write-Host` statements before session end

## Auto-Accept Permissions

Use with caution:
- Enable for trusted, well-defined plans
- Disable for exploratory work
- Never use dangerously-skip-permissions flag

## TodoWrite Best Practices

Use TodoWrite tool to:
- Track progress on multi-step tasks
- Verify understanding of instructions
- Enable real-time steering
- Show granular implementation steps

Todo list reveals:
- Out of order steps
- Missing items
- Extra unnecessary items
- Wrong granularity
- Misinterpreted requirements
