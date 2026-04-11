---
name: continuous-learning
description: Use when closing a session where a non-trivial problem was solved. Guides automatic extraction of reusable patterns and saves them as learned skills via the /learn command.
---

# Continuous Learning

Captures reusable patterns discovered during a session and saves them as learned skills for future sessions.

## When to Activate

- You solved a tricky runspace or concurrency bug
- You found a PowerShell quirk or limitation
- You devised a new pattern for WifiFix (CDF edge case, cluster detection tweak)
- The user corrected your approach — their correction is learnable
- A debugging technique was non-obvious and worth remembering

## How to Use

1. At the end of a session (or when something clicks), run `/learn`
2. The `/learn` command reviews the session and drafts a skill file
3. Confirm the draft — it is saved to `.claude/skills/learned/[pattern-name].md`

## Pattern Types to Detect

| Type | Examples |
|------|---------|
| `error_resolution` | PSParser errors, runspace exceptions, dot-source failures |
| `user_corrections` | User rejected approach X, preferred approach Y |
| `workarounds` | PowerShell 5.1 quirk, `ping.exe` output format change |
| `debugging_techniques` | How to inspect `$ps.Streams.Error`, stale probe detection |
| `project_specific` | New CDF edge case, updated bounce-filter heuristic |

## What Makes a Good Learned Skill

**Extract:**
- Root cause + fix pair that took >1 attempt to resolve
- A pattern you'll definitely hit again (concurrency, runspace scope)
- A user preference or convention not yet in rules/

**Skip:**
- Simple typos or copy-paste errors
- One-time external issues (network outage, Windows update)
- Changes already captured in `rules/` or `patterns.md`

## Learned Skill Template

Skills are saved to `.claude/skills/learned/[pattern-name].md`:

```markdown
---
name: [pattern-name]
description: Use when [specific trigger]. Covers [problem domain].
---

# [Descriptive Pattern Name]

**Extracted:** [Date]
**Context:** [When this applies]

## Problem
[What problem this solves - be specific]

## Solution
[The pattern, technique, or workaround]

## Example
```powershell
# PowerShell example if applicable
```

## When to Use
[Trigger conditions]
```

## Automation Note

On Linux/macOS, the workshop version of this skill includes a `suggest-compact.sh` Stop hook
that automatically evaluates sessions and prompts `/learn` when patterns are detected.
On Windows, the `/learn` command serves as the manual equivalent.
A Node.js-based evaluator could be added to the Stop hooks in `hooks.json` if automatic
prompting becomes desirable.

## Related

- `/learn` command — Manual pattern extraction mid-session
- `.claude/skills/learned/` — Where extracted skills are stored
- `rules/patterns.md` — Project-level patterns (promote here if broadly applicable)
