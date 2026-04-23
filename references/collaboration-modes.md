# Collaboration Modes — Detailed Reference

Seven collaboration modes (scout + six implementation modes: A–F). SKILL.md lists the one-line summary; this file has the diagrams, examples, and constraints for each.

## Mode 0: Scout / Exploration Delegation

**When:** The task is read-heavy, search-heavy, or evidence-heavy, and Claude Code mainly needs Codex to gather facts from the repo or local data.

**Examples:** "Find where tenant IDs are derived", "Inspect these logs and summarize failure clusters", "Map the call sites of this API", "Check whether the migration touched all consumers."

```
Claude Code                          Codex (--read-only unless writes are needed)
    │                                   │
    ├─ Define question + boundaries     │
    ├─ Call ask_codex.sh ─────────────→ │
    │   (prefer --read-only)            ├─ Search repo / inspect data / run commands
    │                                   ├─ Gather evidence with file paths + command output
    │                                   ├─ Return findings
    │ ←──────────────── output_path ────┤
    ├─ Review evidence                  │
    ├─ Synthesize answer / choose next  │
    └─ Optionally escalate into impl    │
```

**Default stance:** If Claude Code catches itself about to do a broad repo/data exploration pass, stop and use this mode first.

**Typical triggers:**
- Need to inspect more than a handful of files to answer confidently
- Need shell-heavy evidence gathering rather than product reasoning
- Need structured findings from logs/data/artifacts
- Task resembles a "cheap background subagent" job that would otherwise go to Haiku

## Mode A: Single Delegation

**When:** Clearly bounded, standalone, standard-quality implementation tasks.

**Examples:** "Add pagination to UserList", "Write a date formatting utility", "Fix this CSS layout issue."

```
Claude Code                          Codex
    │                                   │
    ├─ Understand problem, read files   │
    ├─ Compose task prompt              │
    ├─ Call ask_codex.sh ─────────────→ │
    │                                   ├─ Explore codebase
    │                                   ├─ Implement changes
    │                                   ├─ Return result
    │ ←──────────────── output_path ────┤
    ├─ Read result                      │
    ├─ Read changed files to verify     │
    └─ Report to user                   │
```

**Example invocation:**

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh \
  "Add pagination to the UserList component. Requirements: 20 items per page, support prev/next navigation, preserve existing filter state." \
  --file src/components/UserList.tsx \
  --file src/hooks/useUsers.ts
```

## Mode B: Parallel Delegation

**When:** Multiple independent subtasks with no file overlap.

**Examples:** "Add parameter validation to these 3 API endpoints", "Write unit tests for these components."

```
Claude Code
    ├─ Split into N independent subtasks
    ├─ Launch Codex 1 (Bash run_in_background: true) ──→ Subtask 1
    ├─ Launch Codex 2 (Bash run_in_background: true) ──→ Subtask 2
    ├─ Launch Codex 3 (Bash run_in_background: true) ──→ Subtask 3
    │   ... wait for all to complete ...
    ├─ Collect all results
    ├─ Check for file conflicts (manually merge if any)
    └─ Run overall verification (tests, etc.)
```

**Key constraints:**
- Subtasks must not overlap in files (otherwise they'll conflict)
- Each subtask prompt must be fully self-contained
- Recommended max parallelism: 3 (avoid resource contention)

## Mode C: Iterative Review Loop

**When:** High quality requirements, complex logic, or Claude Code has clear acceptance criteria.

**Examples:** "Refactor the auth module", "Implement complex data pipeline", "Fix this concurrency bug."

This is the core innovation of this framework.

```
Claude Code                          Codex
    │                                   │
    ├─ Deep problem analysis            │
    ├─ Compose detailed task prompt     │
    ├─ Call ask_codex.sh ─────────────→ │
    │                                   ├─ Implement
    │                                   ├─ Return result
    │ ←──────────────── output + sid ───┤
    ├─ Review (read changed files +     │
    │   run tests)                      │
    │                                   │
    ├─ [PASS] → Report completion       │
    │                                   │
    ├─ [FAIL] Compose fix instructions  │
    ├─ --session <sid> continue ──────→ │
    │                                   ├─ Fix
    │                                   ├─ Return
    │ ←─────────────────────────────────┤
    ├─ Review again                     │
    │   (max 3 rounds; escalate after)  │
```

**Review loop rules:**
- **Round 1 review:** Read all files Codex changed, run relevant tests, check logical correctness.
- **Fix instructions must be specific:** Tell Codex which file, which line, what's wrong, what behavior is expected. Never just say "there's a bug."
- **Max 3 rounds:** If issues remain after 3 rounds, stop the loop and report to user: completed parts + unresolved issues + analysis.
- **Session reuse:** Send fix instructions via `--session <sid>` to preserve Codex's context.

**Fix instruction prompt template:**

```
The previous implementation has the following issues. Please fix them:

1. [file:line] [specific problem description] → Expected behavior: [...]
2. [file:line] [specific problem description] → Expected behavior: [...]

Do not modify parts that are already correct. After fixing, explain what you changed.
```

## Mode D: Feasibility Check

**When:** Claude Code has designed an approach and wants Codex to verify feasibility at the code level.

**Examples:** "I plan to refactor this using the Strategy pattern — let Codex check if the interfaces align."

```
Claude Code                          Codex (--read-only)
    │                                   │
    ├─ Design technical approach        │
    ├─ ask_codex.sh --read-only ──────→ │
    │   "Verify feasibility:            │
    │    [approach description]         ├─ Explore code
    │    Check:                         ├─ Check deps, interfaces, constraints
    │    1) Dependencies exist?         ├─ Return assessment
    │    2) Interfaces match?           │
    │    3) Technical blockers?"        │
    │ ←─────────────────────────────────┤
    ├─ Adjust approach based on feedback│
    └─ Decide next step                 │
```

**Note:** Feasibility checks use `--read-only` — Codex explores but does not modify files.

## Mode E: Cross Review

**When:** You want the implementer and reviewer to be different agents for independent perspective.

**Examples:** "Codex implemented it, I'll review", "I wrote some logic, let Codex review it."

**Direction 1 — Codex implements → Claude Code reviews (default path):**

Natural extension of Modes A/C. After reading Codex's output, Claude Code performs structured review:
- Read all changed files
- Run tests
- Check: logical correctness, edge cases, naming conventions, consistency with existing code
- If issues found, enter Mode C review loop

**Direction 2 — Claude Code implements → Codex reviews:**

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --read-only \
  "Review the following code changes. Focus on logical correctness and edge case handling.

Changed files:
- src/auth/middleware.ts (new token validation logic)
- src/auth/types.ts (new TokenPayload type)

Review focus:
1. Is token expiration handling complete?
2. Do all error paths return appropriate HTTP status codes?
3. Any injection or bypass risks?" \
  --file src/auth/middleware.ts \
  --file src/auth/types.ts
```

After receiving Codex's review, Claude Code **independently decides whether to adopt** suggestions (never blindly follow).

## Mode F: Brokered Collaboration

**When:** The task is long-running, likely to need clarification mid-flight, or valuable enough that Claude Code should monitor progress and steer the implementation instead of waiting for a single terminal artifact.

**Examples:** Creating large notebooks, staged refactors, multi-file migrations, investigations that may branch based on findings.

```
Claude Code                          Broker                            Codex
    │                                   │                                │
    ├─ Start broker session ──────────→ │                                │
    │                                   ├─ Launch turn 1 ──────────────→ │
    │                                   │                                ├─ Work + emit progress
    │ ←──────── status / summary ────── │                                │
    ├─ Inspect progress                 │                                │
    ├─ send follow-up / interrupt ────→ │                                │
    │                                   ├─ Queue or restart next turn ─→ │
    │ ←──────── status / summary ────── │                                │
    └─ Stop broker when satisfied      │                                │
```

**Why this mode exists:**
- Avoids the "Claude only sees the corpse" problem of one-shot execution
- Lets Claude Code inspect live progress and steer before Codex drifts too far
- Keeps a persistent Codex session id while still exposing broker-level queue/status controls

**Broker workflow at a glance:** `start` → inspect with `status` → `send` follow-ups (optionally `--interrupt`) → `wait` for drain → `stop`.

Full commands and flags live in `references/invocation.md` under "codex_broker.sh — live collaboration."
