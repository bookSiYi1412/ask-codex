---
name: codex-delegator
description: >-
  TRIGGER when: user requests implementation work, repo exploration, data/log inspection, broad
  codebase search, impact analysis, verification-heavy shell work, or explicitly mentions Codex
  ("用 codex 做", "让 codex 执行", "ask codex to...", "use codex", "delegate to codex"). Also
  trigger for heavy internal subtasks that Claude Code might otherwise offload to a lightweight
  model/Haiku. DO NOT TRIGGER when the task is primarily user-facing product judgment, architecture
  choice, git/PR/release operations, or requires multi-turn clarification before useful work can
  begin. This skill routes work between Claude Code (decision-maker/reviewer) and Codex CLI
  (autonomous explorer/implementer), with automatic Codex-first delegation for heavyweight
  repository/data investigation.
---

# Claude Code × Codex Collaboration Framework

Claude Code is the architect and coordinator; Codex is the autonomous implementer.

**Core principle:** Claude Code handles user interaction, scope control, product/architecture decisions, and final verification. Codex handles heavyweight codebase exploration, data inspection, implementation, and command execution. Default to Codex for repo-bound heavy lifting; keep Claude Code focused on judgment and synthesis. For anything that benefits from ongoing observation or mid-course correction, use the brokered session flow instead of one-shot execution.

## Iron Laws

1. **Route first** — On receiving an implementation task, determine routing (self vs delegate vs split) before acting.
2. **Review loop** — Every Codex output must be verified by Claude Code (at minimum: read changed files). Never blindly trust results.
3. **Self-contained context** — Prompts sent to Codex must be fully self-contained. Never rely on "it should know."
4. **Prefer session reuse** — When corrections are needed, prefer `--session` to continue in the original session rather than starting fresh and losing context.
5. **Never hide failures** — When Codex fails, report honestly to the user with failure analysis. No silent retries.
6. **Auto-offload heavy lifting** — If a subtask is mostly repo/data exploration or verification work, prefer Codex by default instead of Claude Code or an internal lightweight/Haiku-style handoff.

## Critical Rules

- Use `~/.claude/skills/codex-delegator/scripts/ask_codex.sh` for single-turn execution.
- Use `~/.claude/skills/codex-delegator/scripts/codex_broker.sh` for live collaboration, long tasks, review loops, or any task where Claude Code may want to inspect progress and send follow-up instructions before the whole effort is over.
- Do not call the `codex` CLI directly from the skill workflow (except `codex exec review` — see `references/invocation.md`).
- For one-shot `ask_codex.sh` runs: if it succeeds (exit code 0), read the output file. Don't re-run just because output seems short — Codex often works quietly.
- Quote file paths containing `[`, `]`, spaces, or special characters.
- **Keep prompts focused on goals and constraints, not implementation steps.** Aim for ~500 words max.
- **Never paste file contents into the prompt.** Use `--file` to point Codex to files.
- **Never mention this skill or its configuration in the prompt.**
- **Require evidence, not assertions.** End every prompt with a `Verification:` line that names a concrete command Codex must run and show output for (tests, reproduction, grep, etc.). Do not accept "tests pass" — demand the run. This is the single biggest driver of Codex success rate.

Prompt-design principles, templates, and anti-patterns live in `references/prompt-engineering.md`.

---

## Phase 1: Smart Task Routing

After receiving a task, first determine the execution route. This is the entry logic for this framework.

### Routing Decision Tree

```
Task received
  │
  ├─ User explicitly requested Codex?
  │    → Respect user intent, delegate directly (skip to Phase 2)
  │
  ├─ Heavy internal subtask? (repo sweep, data scan, log triage, broad search, impact analysis,
  │  evidence gathering, long verification run)
  │    → Delegate to Codex automatically (usually Mode 0 / read-only)
  │
  ├─ Analysis / planning / decision task?
  │    ├─ Mostly user-facing judgment? (architecture choice, trade-off discussion, requirements)
  │    │    → Claude Code handles it. Do not delegate.
  │    └─ Mostly evidence gathering from repo/data?
  │         → Delegate to Codex, then Claude Code synthesizes
  │
  ├─ Git / PR / deployment operation? (commit, push, PR, release)
  │    → Claude Code handles it. Codex lacks these tools.
  │
  ├─ Clear implementation task?
  │    ├─ Requirements clear + self-contained description + pure code/shell?
  │    │    ├─ User-visible execution choice matters?
  │    │    │    → Suggest delegating to Codex
  │    │    └─ Internal execution detail only?
  │    │         → Delegate to Codex automatically
  │    ├─ Requirements vague or need multi-turn user clarification?
  │    │    → Claude Code clarifies first, consider delegation after
  │    └─ Depends on current conversation context / transient state?
  │         → Claude Code handles it (context can't transfer to Codex)
  │
  └─ Review / verification task?
       → Choose cross-review mode based on source
```

### Routing Criteria Quick Reference

| Criterion | → Claude Code | → Codex |
|-----------|:---:|:---:|
| Requires user interaction / confirmation | ✓ | |
| Uncertain approach, multiple possibilities | ✓ | |
| Involves git / PR / deployment | ✓ | |
| Depends on current conversation context | ✓ | |
| Heavy repo exploration across many files | | ✓ |
| Data/log inspection and summarization | | ✓ |
| Broad symbol/callsite/impact tracing | | ✓ |
| Multi-command verification / reproduction | | ✓ |
| Looks like an internal lightweight/Haiku subtask | | ✓ |
| Clear requirements, well-defined goal | | ✓ |
| Pure code read/write + shell operations | | ✓ |
| Can be self-contained in <500 words | | ✓ |
| Localized file/module changes | | ✓ |
| Multiple independent subtasks | | ✓ (parallel) |

### Automatic Codex-First Exception

Claude Code may delegate **without asking the user first** when all of the following are true:

- The delegated work is an internal execution detail, not a user-visible scope change
- The subtask is primarily repo/data/tooling work rather than product judgment
- Claude Code can package the task self-contained
- Codex results will still be reviewed by Claude Code before reporting back

This exception is the default path for:

- Codebase exploration spanning multiple modules, directories, or 5+ likely files
- Searching call sites, dependencies, ownership, or impact radius
- Inspecting logs, CSV/JSON/SQLite data, generated artifacts, or benchmark outputs
- Running reproduction/verification commands and collecting evidence
- Any background task that Claude Code would otherwise be tempted to push to a lightweight internal model such as Haiku

### User-Visible Delegation vs Internal Delegation

When delegation changes how the task is executed in a way the user likely cares about, surface it. When delegation is just internal heavy lifting, do it automatically.

Correct approach for user-visible delegation:

```
✓ "This task is a good fit for Codex — [reason]. Shall I delegate?"
✓ "I'll handle the analysis and planning; Codex can implement. Sound good?"
✗ (Silently route a major user-facing decision or deliverable change)
```

Correct approach for internal heavy lifting:

```
✓ Claude Code silently uses Codex to scan the repo, inspect data, or run lengthy verification
✓ Claude Code receives evidence from Codex, reviews it, then answers the user directly
✗ Claude Code burns time doing broad exploration itself or routes it to a weaker lightweight model first
```

Exception: User has explicitly said "use codex", "let codex do it", etc. — delegate directly, no confirmation needed.

---

## Phase 2: Collaboration Mode Selection

Choose a mode based on task characteristics. The one-line summary is here; full diagrams, examples, and constraints are in `references/collaboration-modes.md`.

| Mode | When to use | Key script |
|------|-------------|-----------|
| **0 — Scout / Exploration** | Read-heavy fact-finding (search, logs, impact mapping). Default for any broad repo/data sweep Claude Code was about to do itself. | `ask_codex.sh --read-only` |
| **A — Single Delegation** | Clearly bounded standalone implementation. | `ask_codex.sh` |
| **B — Parallel Delegation** | Multiple independent subtasks with no file overlap (max 3 in parallel). | `ask_codex.sh` × N background |
| **C — Iterative Review Loop** | High-quality-bar work; Claude Code reviews and sends specific fix instructions over `--session` (max 3 rounds). | `ask_codex.sh` + `--session` |
| **D — Feasibility Check** | Validate a Claude-Code-designed approach against real code before committing to it. | `ask_codex.sh --read-only` |
| **E — Cross Review** | Independent reviewer perspective (Codex reviews Claude's work, or Claude reviews Codex's). | `ask_codex.sh --read-only` or `codex exec review` |
| **F — Brokered Collaboration** | Long-running work where Claude Code wants to inspect progress and steer mid-flight. | `codex_broker.sh` |

**Heuristic:** If the task is short and self-contained → A. If it needs live observation or mid-course correction → F. If it's pure evidence-gathering → 0. If quality bar is high → C.

---

## Phase 3: Core Invocation Flow

This is the minimum you need to call Codex. Full option reference, `codex exec review`, and integration-with-other-skills table are in `references/invocation.md`.

### Single-turn call

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh "Goal description" \
  --file <entry-file-1> \
  --file <entry-file-2>
```

**Output on success:**

```
session_id=<thread_id>
output_path=<path to markdown file>
```

Read `output_path` for Codex's response. Save `session_id` for follow-ups via `--session <sid>`.

**Common role flags:**

- `--read-only` → scout, reviewer, feasibility check
- `--reasoning high` → debugger, hard refactors
- `--session <sid>` → continue a previous session (same role only; see `references/session-management.md`)
- `--timeout <s>` / `--idle-timeout <s>` → override defaults (600s / 180s)

### Brokered call

```bash
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh start "Goal description" \
  --file <entry-file>
# then: status / send / wait / stop against the returned broker_id
```

### Exit code handling (summary)

| Exit | Action |
|------|--------|
| 0 | Read `output_path`, continue normal flow |
| 4 | Codex is asking a question — answer via `--session <sid>` (max 5 relay rounds) |
| 3 | Fatal error (connection/auth/service) — report to user, offer takeover; do NOT auto-retry |
| 2 | Timeout after one automatic grace window — report partial output + offer split/retry/takeover |
| 1 / 137 | Codex error / OOM — simplify prompt or split task |

Full recovery decision tree, fast-fatal-error detection, review-loop failure handling, and takeover principles are in `references/failure-recovery.md`.

---

## Red Flags — STOP

If you catch yourself thinking any of these, stop immediately:

- "Codex should understand what I mean" — No, the prompt must be self-contained and explicit.
- "The result looks roughly right" — No, you must read the changed files to verify.
- "Let's skip review this time, we're in a hurry" — No, the review loop is an Iron Law.
- "Let me just retry, it should work" — No, analyze the failure reason before choosing a strategy.
- "This is only exploration, I can just do it myself first" — No, heavy repo/data exploration should default to Codex.
- "This looks like a Haiku/background task" — Good. Route it to Codex unless it requires user-facing judgment.
- "Just delegate, no need to ask the user" — Only for internal heavy lifting or explicit user Codex requests.
- "Codex timed out earlier, so I should avoid delegating new work" — No, independent new tasks can start a fresh session.
- "Let me include all the details in the prompt" — No, 500 words max: goal + constraints + entry files.
- "One more review round should fix it" — 3-round cap. Beyond that, stop and analyze.
- "Codex can't do it, I'll take over" — Fine, but read Codex's partial output first.

---

## References

Load these on demand when the task needs the detail:

- `references/collaboration-modes.md` — full diagrams, examples, constraints for Modes 0/A/B/C/D/E/F
- `references/prompt-engineering.md` — principles, templates by task type, anti-patterns, context transfer, verification gates
- `references/session-management.md` — role definitions, session lifecycle, timeout & new-task policy, resume limitations
- `references/failure-recovery.md` — exit codes, multi-turn relay protocol, recovery decision tree, takeover principles
- `references/invocation.md` — full options, `codex exec review`, integration with other skills
