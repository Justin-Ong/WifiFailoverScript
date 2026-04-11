---
name: strategic-compact
description: Strategic context compaction at logical phase boundaries to preserve critical context through task phases rather than losing it to arbitrary auto-compaction.
---

# Strategic Compact

## When to Activate

Suggests manual context compaction at logical intervals to preserve context through task phases rather than arbitrary auto-compaction.

## Why Strategic Compaction

Auto-compaction triggers at arbitrary points — often mid-task, cutting off critical state.
Strategic compaction at phase boundaries preserves what matters:

- **After exploration, before execution** – Compact research context, keep implementation plan
- **After RED phase, before GREEN phase** – Assert statements are written; compact before implementing
- **After feature complete, before next** – Fresh context for the next PRP
- **After a complex debugging session** – Clear error-investigation noise before continuing

## When to Compact

Good compaction points:
- After planning with `/plan`, before starting `/tdd`
- After tests written (RED), before implementing (GREEN)
- After implementing, before refactoring
- After feature complete, before next feature
- After a long debugging session involving runspace or CDF issues

## What to Preserve

When compacting, ensure these survive in your summary:
- Current task and progress
- Key decisions made and why
- File paths and function names being worked on
- Test results (which pass, which fail)
- State of the PRP being implemented
- Any unresolved blockers

## How to Use

At a natural phase boundary, write a compact summary:

```markdown
## Pre-Compact Summary

**Current task:** [PRP-XX feature name]
**Completed:** [What's done]
**Next:** [What comes next]
**Key files:** WifiFix-Functions.ps1:42 (Get-X), tests/test_04_degradation.ps1
**Test state:** test_01–04 PASS, test_05 FAIL (expected — not yet implemented)
**Decisions:** [Any architectural choices made]
**Blockers:** [Any open issues]
```

Then use `/compact` to apply.

## Best Practices

1. **Compact at boundaries** – Between phases, not mid-task
2. **Preserve decisions** – Why choices were made, not just what
3. **Keep file paths** – Which files are being modified and at which lines
4. **Note test state** – Which suites pass, which fail, and why
5. **Flag blockers** – Anything unresolved that must carry forward

## Automation (Optional)

The workshop version of this skill ships a `suggest-compact.sh` that tracks tool-call count
and prints a reminder at 50 calls and every 25 calls after. On Windows you can replicate
this with a Node.js hook in `hooks.json`:

```json
// Two separate hook entries (|| is not supported in Claude Code matcher syntax)
{ "matcher": "tool == \"Edit\"", "hooks": [{ "type": "command", "command": "..." }] },
{ "matcher": "tool == \"Write\"", "hooks": [{ "type": "command", "command": "..." }] }
```

The counter command (using PID for per-session isolation):
```js
node -e "const f=require('os').tmpdir()+'/claude-calls-'+process.ppid+'.txt';const fs=require('fs');let n=0;try{n=+fs.readFileSync(f,'utf8')||0}catch{}n++;fs.writeFileSync(f,String(n));const t=50;if(n===t||n>t&&n%25===0)console.error('[StrategicCompact] '+n+' tool calls — consider /compact at next phase boundary');"
```

Add this to `PreToolUse` in `.claude/hooks.json` if automatic reminders are wanted.
