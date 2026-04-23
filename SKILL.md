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

Claude Code is the architect and coordinator; Codex is the autonomous implementer. They collaborate through structured protocols, each leveraging its strengths.

**Core principle:** Claude Code handles user interaction, scope control, product/architecture decisions, and final verification. Codex handles heavyweight codebase exploration, data inspection, implementation, and command execution. Default to Codex for repo-bound heavy lifting; keep Claude Code focused on judgment and synthesis. For anything that benefits from ongoing observation or mid-course correction, use the brokered session flow instead of one-shot execution.

## Iron Laws

1. **Route first** — On receiving an implementation task, determine routing (self vs delegate vs split) before acting.
2. **Review loop** — Every Codex output must be verified by Claude Code (at minimum: read changed files). Never blindly trust results.
3. **Self-contained context** — Prompts sent to Codex must be fully self-contained. Never rely on "it should know."
4. **Prefer session reuse** — When corrections are needed, prefer `--session` to continue in the original session rather than starting fresh and losing context.
5. **Never hide failures** — When Codex fails, report honestly to the user with failure analysis. No silent retries.
6. **Auto-offload heavy lifting** — If a subtask is mostly repo/data exploration or verification work, prefer Codex by default instead of Claude Code or an internal lightweight/Haiku-style handoff.

## Critical Rules (inherited from v1)

- Use `~/.claude/skills/codex-delegator/scripts/ask_codex.sh` for single-turn execution.
- Use `~/.claude/skills/codex-delegator/scripts/codex_broker.sh` for live collaboration, long tasks, review loops, or any task where Claude Code may want to inspect progress and send follow-up instructions before the whole effort is over.
- Do not call the `codex` CLI directly from the skill workflow.
- For one-shot `ask_codex.sh` runs: if it succeeds (exit code 0), read the output file. Don't re-run just because output seems short — Codex often works quietly.
- Quote file paths containing `[`, `]`, spaces, or special characters.
- **Keep prompts focused on goals and constraints, not implementation steps.** Aim for ~500 words max.
- **Never paste file contents into the prompt.** Use `--file` to point Codex to files.
- **Never mention this skill or its configuration in the prompt.**

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

Choose the appropriate collaboration mode based on task characteristics.

### Mode 0: Scout / Exploration Delegation

**When:** The task is read-heavy, search-heavy, or evidence-heavy, and Claude Code mainly needs Codex to gather facts from the repo or local data.
**Examples:** "Find where tenant IDs are derived", "Inspect these logs and summarize failure clusters", "Map the call sites of this API", "Check whether the migration touched all consumers."

```
Claude Code                          Codex (--read-only unless writes are needed)
    │                                   │
    ├─ Define question + boundaries      │
    ├─ Call ask_codex.sh ──────────────→ │
    │   (prefer --read-only)             ├─ Search repo / inspect data / run commands
    │                                    ├─ Gather evidence with file paths + command output
    │                                    ├─ Return findings
    │ ←──────────────── output_path ─────┤
    ├─ Review evidence                   │
    ├─ Synthesize answer / choose next   │
    └─ Optionally escalate into impl     │
```

**Default stance:** If Claude Code catches itself about to do a broad repo/data exploration pass, stop and use this mode first.

**Typical triggers:**
- Need to inspect more than a handful of files to answer confidently
- Need shell-heavy evidence gathering rather than product reasoning
- Need structured findings from logs/data/artifacts
- Task resembles a "cheap background subagent" job that would otherwise go to Haiku

### Mode A: Single Delegation (Delegate)

**When:** Clearly bounded, standalone, standard-quality implementation tasks.
**Examples:** "Add pagination to UserList", "Write a date formatting utility", "Fix this CSS layout issue."

```
Claude Code                          Codex
    │                                   │
    ├─ Understand problem, read files    │
    ├─ Compose task prompt               │
    ├─ Call ask_codex.sh ──────────────→ │
    │                                    ├─ Explore codebase
    │                                    ├─ Implement changes
    │                                    ├─ Return result
    │ ←──────────────── output_path ─────┤
    ├─ Read result                       │
    ├─ Read changed files to verify      │
    └─ Report to user                    │
```

**Example invocation:**

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh \
  "Add pagination to the UserList component. Requirements: 20 items per page, support prev/next navigation, preserve existing filter state." \
  --file src/components/UserList.tsx \
  --file src/hooks/useUsers.ts
```

### Mode B: Parallel Delegation (Parallel Delegate)

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

### Mode C: Iterative Review Loop

**When:** High quality requirements, complex logic, or Claude Code has clear acceptance criteria.
**Examples:** "Refactor the auth module", "Implement complex data pipeline", "Fix this concurrency bug."

This is the core innovation of this framework.

```
Claude Code                          Codex
    │                                   │
    ├─ Deep problem analysis             │
    ├─ Compose detailed task prompt      │
    ├─ Call ask_codex.sh ──────────────→ │
    │                                    ├─ Implement
    │                                    ├─ Return result
    │ ←──────────────── output + sid ────┤
    ├─ Review (read changed files +      │
    │   run tests)                       │
    │                                    │
    ├─ [PASS] → Report completion        │
    │                                    │
    ├─ [FAIL] Compose fix instructions   │
    ├─ --session <sid> continue ────────→ │
    │                                    ├─ Fix
    │                                    ├─ Return
    │ ←─────────────────────────────────┤
    ├─ Review again                      │
    │   (max 3 rounds; escalate after)   │
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

### Mode D: Feasibility Check

**When:** Claude Code has designed an approach and wants Codex to verify feasibility at the code level.
**Examples:** "I plan to refactor this using the Strategy pattern — let Codex check if the interfaces align."

```
Claude Code                          Codex (--read-only)
    │                                   │
    ├─ Design technical approach         │
    ├─ ask_codex.sh --read-only ───────→ │
    │   "Verify feasibility:              │
    │    [approach description]           ├─ Explore code
    │    Check:                           ├─ Check deps, interfaces, constraints
    │    1) Dependencies exist?           ├─ Return assessment
    │    2) Interfaces match?             │
    │    3) Technical blockers?"          │
    │ ←─────────────────────────────────┤
    ├─ Adjust approach based on feedback  │
    └─ Decide next step                  │
```

**Note:** Feasibility checks use `--read-only` — Codex explores but does not modify files.

### Mode E: Cross Review

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

### Mode F: Brokered Collaboration

**When:** The task is long-running, likely to need clarification mid-flight, or valuable enough that Claude Code should monitor progress and steer the implementation instead of waiting for a single terminal artifact.
**Examples:** Creating large notebooks, staged refactors, multi-file migrations, investigations that may branch based on findings.

```
Claude Code                          Broker                            Codex
    │                                   │                                │
    ├─ Start broker session ───────────→ │                                │
    │                                    ├─ Launch turn 1 ──────────────→ │
    │                                    │                                ├─ Work + emit progress
    │ ←──────── status / summary ─────── │                                │
    ├─ Inspect progress                  │                                │
    ├─ send follow-up / interrupt ─────→ │                                │
    │                                    ├─ Queue or restart next turn ─→ │
    │ ←──────── status / summary ─────── │                                │
    └─ Stop broker when satisfied       │                                │
```

**Why this mode exists:**
- Avoids the "Claude only sees the corpse" problem of one-shot execution
- Lets Claude Code inspect live progress and steer before Codex drifts too far
- Keeps a persistent Codex session id while still exposing broker-level queue/status controls

**Broker commands:**

```bash
# Start a brokered session
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh start "Implement task..." --file src/main.ts

# Inspect current state
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh status <broker_id>

# Queue a follow-up instruction
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh send <broker_id> "Also add validation."

# Interrupt current work and redirect
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh send <broker_id> "Change direction..." --interrupt

# Wait until the queue drains and Codex is idle
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh wait <broker_id> --timeout 600

# Stop the broker session
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh stop <broker_id>
```

---

## Phase 3: Prompt Engineering Guide

Codex output quality depends heavily on prompt design. The following principles are distilled from 22 real-world runs analyzing success/failure patterns.

### Core Principles

#### 1. Verification Gates (the single most impactful optimization)

**Require Codex to show tool execution output, not accept its assertions.** This alone raises Codex success rate from ~60% to ~95%.

```
✗ "Make sure tests pass"              → Codex may claim "tests pass" without running them
✓ "Run pytest -v and show the output" → Codex must execute and show real results

✗ "Check if this function has bugs"   → Codex may give speculative analysis
✓ "Run this function with test input, show actual output vs expected" → Codex must verify with tools
```

Append explicit verification requirements at the end of every prompt:

```
Verification: After completing, run [specific command] and show the full output.
Do not just say "tests pass" — show the actual test run results.
```

#### 2. Structured Constraints Over Narrative

List constraints as bullet points in the prompt body. Codex frequently misses constraints buried in paragraphs.

```
✗ "Note that this project uses React 18, and we have a convention that all state
   management uses zustand not redux, also component filenames use PascalCase..."

✓ Constraints:
  - React 18 (do not use deprecated APIs)
  - State management: zustand only, not redux
  - Component filenames: PascalCase
```

#### 3. Goal-Driven, Not Step-by-Step

Codex has a full toolchain (file read/write, grep, bash) and explores the codebase on its own. Tell it "what" and "why", not "how."

```
✗ "First read src/auth.ts, find the validateToken function, change == on line 42 to ===, then run tests"
✓ "Fix the type comparison bug in validateToken. Loose equality causes string tokens to unexpectedly pass numeric validation."
```

**Exception:** If Claude Code has already done deep analysis and located the root cause, provide the specific location as a **starting hint**, not a mandatory path:

```
✓ "Fix the token validation type comparison bug. Starting point: validateToken function
   in src/auth.ts. Root cause: loose equality == lets string '0' pass numeric 0 validation."
```

#### 4. Entry File Strategy

- **Use `--file` for 1–4 entry-point files.** Codex will discover related files on its own from these starting points.
- **Choose the most relevant entries**, don't enumerate everything possibly related.
- **Never paste file contents into the prompt** — `--file` lets Codex read the current version directly, avoiding token waste and version staleness.

#### 5. Single Responsibility

One prompt, one job. Don't combine review, implementation, and documentation in a single prompt.

```
✗ "Review this code, fix issues found, then update the docs"
✓ Three separate calls: review → implement fixes → update docs
```

Runtime data shows: prompts mixing 3+ goals see ~40% quality drop, while single-responsibility long tasks (20K+ output) produce the highest quality.

#### 6. Leverage Codex's Built-in Skills and AGENTS.md

Codex automatically reads `AGENTS.md` files from the project root. If the project already has an AGENTS.md, don't repeat project conventions in the prompt. Codex also has its own installed skills (e.g., TDD, brainstorming) — if the project's AGENTS.md references these, Codex will follow them automatically.

### Prompt Templates by Task Type

#### Scout / Exploration (Mode 0)

```
[Concrete question to answer]

Goal:
- [What Claude Code needs to learn]

Scope:
- [Directories / data sources / files to prioritize]
- [What to ignore]

Deliverable:
- Summarize findings with file paths / command evidence
- Highlight unknowns or conflicting signals

Constraints:
- Do not modify files unless explicitly requested
- Do not speculate beyond inspected evidence

Verification: Show the commands run and the key evidence that supports each conclusion.
```

#### Implementation (Modes A/B/C)

```
[One-sentence goal]

Context: [Why this is needed — non-obvious motivation or background]

Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
- [Specific requirement 3]

Constraints:
- [Must-follow technical constraints]
- [Things NOT to do]

Verification: After completing, run [specific test command] and show full output.
```

**Good implementation prompt example:**

```
Extract duplicated character metadata from 5 scripts in scripts/ into a shared module scripts/kotor_characters.py.

Context: Currently 5 scripts each hardcode character names, aliases, and speech patterns. Changing one character requires editing 5 files.

Requirements:
- Create scripts/kotor_characters.py as the single source of truth
- Update 5 scripts to use: from scripts.kotor_characters import ...
- Use try/except ImportError for backward compatibility (support direct script execution)
- Do not change any script's external behavior

Constraints:
- Do not modify data content, only move locations
- All existing tests must continue to pass

Verification: Run pytest tests/ -v and show all tests passing.
```

#### TDD Implementation (highest-quality pattern)

Runtime data shows: prompts with TDD red/green gates achieve near-100% success rate.

```
[Feature goal]

Context: [Background]

Use TDD workflow:
1. Write the test first (follow the style of [existing test file])
2. Run the test, show the FAILED output (red)
3. Implement the feature
4. Run the test again, show the PASSED output (green)

Requirements:
- [Specific requirements]

Constraints:
- [Constraints]

Verification: Show the complete red → green test output progression.
```

#### Code Review

For structured review of git changes, prefer Codex's built-in `review` subcommand:

```bash
# Review uncommitted changes
codex exec review --uncommitted --json "Focus on: security vulnerabilities, logic errors, edge case handling"

# Review branch changes against main
codex exec review --base main --json "Check API compatibility and error handling"

# Review a specific commit
codex exec review --commit abc123 --json
```

For deeper custom review (e.g., feasibility validation), use `ask_codex.sh --read-only`:

```
Review the following changes for correctness and potential issues.

Scope: [describe which files changed and what was modified]

Review focus:
1. [Specific concern 1]
2. [Specific concern 2]
3. [Specific concern 3]

For each issue: cite the file and line number, explain the problem, suggest a fix direction.
Do not be vague — only report issues you've confirmed by reading the actual code.
```

#### Debugging (with --reasoning high)

```
[Bug symptom description]

Reproduction: [Specific steps/input]
Already investigated: [Directions Claude Code has analyzed and ruled out]

Locate the root cause and fix it.
- First, reproduce the bug with tools (run relevant commands, show error output)
- Analyze root cause
- Fix
- Re-run the reproduction command, show the bug is gone

Investigation priorities:
- [Suspected cause 1, with evidence]
- [Suspected cause 2, with evidence]

Verification: Show before/after comparison output.
```

#### Feasibility Validation (Mode D, with --read-only)

```
Verify the feasibility of the following technical approach (do not modify any files):

Approach: [Approach description]

Please check:
1. Does [API/module the approach depends on] exist and match the expected interface?
2. Does [key assumption] hold? — Read the relevant code to confirm.
3. Are there technical blockers preventing implementation?

For each check: show which files you read or commands you ran to verify. Give your conclusion.
Do not speculate — answer only based on code you actually read.
```

### Prompt Anti-Patterns (Lessons Learned)

| Anti-Pattern | Consequence | Fix |
|-------------|-------------|-----|
| "Make sure tests pass" | Codex claims pass without running | "Run pytest -v and show output" |
| "Consider whether tests are needed" | Codex skips testing | "Write test first, show FAILED" |
| "Review, refactor, and document" | All three done halfway | Split into 3 separate calls |
| Prompt exceeds 500 words | Constrains Codex's exploration space | Trim; use --file instead of pasting content |
| Key constraints buried in paragraphs | Codex misses them | Use bullet-point lists |
| "Improve this code" | Codex doesn't know the improvement direction | "Improve readability without changing behavior" |
| Repeating current conversation context | Wastes tokens + stale info | Write only what Codex needs, self-contained |
| Dictating step-by-step instructions | Limits Codex's exploration ability | State goals and constraints; let Codex plan the path |

### Context Transfer Strategy

Claude Code's analysis-phase insights should be efficiently transferred to Codex:

| Information Type | Transfer Method | Notes |
|-----------------|----------------|-------|
| Entry-point files | `--file` | Most efficient; Codex reads the current version directly |
| Root cause analysis | Prompt body | Distill to 2–3 sentences of conclusions, not the analysis process |
| Existing code style | `--file` pointing to example | "Follow the style of tests/test_auth.py" |
| Technical constraints | Prompt bullet list | Must be explicit in the prompt body |
| Project conventions | AGENTS.md (automatic) | If project has AGENTS.md, don't repeat |
| Large code context | Don't transfer | Codex has its own exploration tools; let it read |

### Verification Requirement Templates

Append the appropriate verification requirement at the end of every prompt:

```
# Scout / exploration
Verification: Show the commands run and the evidence supporting each conclusion.

# Implementation
Verification: Run [test command] and show full output.

# TDD
Verification: Show the complete FAILED → PASSED test output.

# Debugging
Verification: Show before/after comparison output.

# Review
Verification: For each finding, cite the specific file:line. Do not give suggestions without code evidence.

# Feasibility
Verification: For each check, state which files you read or commands you ran to reach your conclusion.
```

---

## Phase 4: Role-Based Session Management

For ongoing projects, maintain named-role Codex sessions, similar to the `/agents` pattern.

### Role Definitions

| Role | Launch Parameters | Purpose |
|------|-------------------|---------|
| **scout** | `--read-only` (often `--reasoning low` or `medium`) | Repo exploration, data inspection, impact mapping, evidence gathering |
| **writer** | (default full-auto) | Code implementation, feature development |
| **reviewer** | `--read-only` or `codex exec review` | Code review, feasibility validation |
| **debugger** | `--reasoning high` | Bug diagnosis and fixes |

**Choosing `codex exec review` vs `ask_codex.sh --read-only`:**
- Structured review of git diff / commit / branch → `codex exec review` (built-in, normalized output)
- Feasibility validation, design review, custom analysis → `ask_codex.sh --read-only` (more flexible)

### Session Lifecycle

```
1. Brokered flow: create a broker_id first, then let the broker discover / persist the Codex session_id
2. Same broker session → use `send` to queue follow-ups instead of starting a fresh task blindly
3. Same-role follow-up without broker → `--session <id>` reuse (preserve context)
4. Role type change → new session (resume doesn't support switching --read-only etc.)
5. Session invalid (not in git repo, errors) → new session, don't force resume
6. Session timed out on one task → treat that task as stalled, not Codex globally blocked
7. New independent task after a timeout → feel free to open a fresh session immediately
```

### Timeout and New-Task Policy

`timeout` applies to the current execution attempt, not to all future Codex use.

Default timeout policy:

- Total timeout window: `600s`
- Idle timeout: `180s`
- Automatic grace windows: `1`

After a timeout:

- The timed-out session may still be useful for the same task if Claude Code wants to retry or continue with `--session`
- Claude Code must not let a stalled session block delegation of a different independent task
- If a new task is unrelated or only loosely related, prefer a fresh Codex session instead of waiting on the old one
- If the original timed-out task is still important, track it separately; do not serialize all later work behind it

Rule of thumb:

- Same task, same thread of work, still valuable context → consider `--session <id>` or a targeted retry
- Different task, different deliverable, or urgency shifted → start a new Codex session

### Resume Limitations

`--session` resume has these limitations (script handles them, but callers should be aware):
- Must be in a git repository
- Cannot switch `--sandbox`, `--read-only`, `--model`
- Output is plain text (not JSON)

When switching from writer to reviewer (requires `--read-only`), a new session is required.

---

## Phase 5: Failure Recovery Strategy

The script uses differentiated exit codes. Claude Code should choose the recovery path based on exit code.

### Exit Code Reference

| Exit Code | Meaning | Typical Cause |
|-----------|---------|---------------|
| **0** | Success | Codex completed normally |
| **1** | Codex error | Error during execution (stderr contains `[ERROR]`) |
| **2** | Timeout | Exceeded the final timeout after one automatic grace window |
| **3** | Early fatal error | Connection failure, auth error, API unavailable |
| **4** | Pending question | Codex is asking a question (e.g., brainstorming confirmation) |
| **137** | OOM / killed | Out of memory or killed by external signal |

### Multi-Turn Relay Protocol (exit code 4)

Codex may pause to ask a question before proceeding (e.g., the brainstorming skill requires design approval, or Codex needs a constraint clarified). When this happens, the script detects the question and returns exit code 4 with the session_id.

**Claude Code's response flow:**

```
ask_codex.sh returns exit 4
    │
    ├─ Read output_path — contains Codex's work so far + the question
    ├─ Read the question text from the "Codex is asking a question" section
    ├─ Claude Code formulates an answer (using its own judgment + user context)
    ├─ Call ask_codex.sh --session <sid> "answer text"
    │    → Codex receives the answer and continues working
    ├─ Check exit code again:
    │    ├─ exit 0 → done, read final output
    │    ├─ exit 4 → another question, repeat the relay
    │    └─ other → handle per normal recovery logic
    └─ Max relay rounds: 5 (prevent infinite Q&A loops)
```

**How Claude Code should answer Codex's questions:**

1. **Brainstorming/design approval questions:** Claude Code already did the design work before delegating. Answer with the design decisions and say "Approved, proceed with implementation."
2. **Constraint clarification questions:** Answer based on the original task context from the user conversation. If unclear, ask the user.
3. **Technical feasibility questions:** Answer based on Claude Code's codebase analysis.

**Example relay interaction:**

```bash
# Initial call
output=$(~/.claude/skills/codex-delegator/scripts/ask_codex.sh "Add pagination to UserList" --file src/UserList.tsx)
# exit code 4 — Codex asks: "Should pagination be client-side or server-side?"

sid=$(echo "$output" | grep "^session_id=" | cut -d= -f2)

# Claude Code answers and continues
output=$(~/.claude/skills/codex-delegator/scripts/ask_codex.sh --session "$sid" \
  "Server-side pagination. The API already supports ?page=N&limit=20 parameters.")
# exit code 0 — done
```

**Key rules for the relay:**
- Claude Code answers on behalf of the user, using context from the current conversation
- If Claude Code cannot confidently answer, ask the user before responding to Codex
- Max 5 relay rounds per task; if exceeded, report to user with conversation history
- Each relay answer should be concise and decisive — Codex needs clear direction, not discussion

### Recovery Decision Tree

```
Script returns
  │
  ├─ exit 0 → Success. Read output_path, continue normal flow.
  │
  ├─ exit 4 (pending question) → Codex needs an answer before continuing
  │    ├─ Read output_path for the question
  │    ├─ Formulate answer (from conversation context / own analysis)
  │    ├─ If unsure → ask the user before answering Codex
  │    ├─ Call: ask_codex.sh --session <sid> "answer"
  │    └─ Check exit code again (may be 0, 4, or other)
  │    ⚠ Max 5 relay rounds. Beyond that, report to user.
  │
  ├─ exit 3 (fatal error) → Codex unavailable
  │    ├─ Read output_path for error details
  │    ├─ Report to user: Codex unavailable + specific error info
  │    └─ Offer choices:
  │         ├─ "I'll handle this task" (Claude Code takes over)
  │         ├─ "Please check Codex config and retry" (user fixes, then retry)
  │         └─ "Skip this task"
  │    ⚠ Do NOT auto-retry — fatal errors (connection refused, auth failure) won't self-heal
  │
  ├─ first timeout threshold hit → Codex gets one automatic grace window
  │    ├─ If still making progress, Claude Code keeps waiting
  │    ├─ Do not report to the user yet
  │    └─ Re-evaluate after the grace window
  │
  ├─ exit 2 (second timeout) → Codex still didn't finish after grace
  │    ├─ Read output_path for partial output captured before timeout
  │    ├─ If session_id was emitted, the task can still be resumed or inspected later
  │    ├─ Report to user: timeout + partial content + current recommendation
  │    └─ Offer choices:
  │         ├─ "Split into smaller tasks and retry"
  │         ├─ "Retry with longer timeout" (--timeout 900 / --idle-timeout 240)
  │         ├─ "I'll take over and complete it" (continue from partial output)
  │         ├─ "I'll continue other independent tasks in a fresh Codex session"
  │         └─ "Skip"
  │
  ├─ exit 1 (Codex error) → Error during execution
  │    ├─ Check stderr to determine error type
  │    ├─ If prompt issue → simplify prompt and retry once
  │    ├─ If sandbox restriction → adjust --sandbox and retry
  │    └─ Otherwise → report error to user + offer choices
  │
  ├─ exit 137 (OOM / killed)
  │    ├─ Split into smaller tasks and retry
  │    └─ Or Claude Code takes over
  │
  └─ Output is "(no response from codex)" (exit 0 but empty)
       ├─ Check stderr for clues
       ├─ Simplify prompt and retry once
       └─ Still no response → Claude Code takes over
```

### Fast Fatal Error Detection

The script monitors stderr in real-time and **immediately terminates Codex with exit 3** upon detecting these patterns (instead of waiting for timeout):

- **Connection:** connection refused/reset/timed out, ECONNREFUSED, ETIMEDOUT
- **Auth:** authentication failed, unauthorized, 401/403, invalid api key/token
- **Service:** 502/503/504, rate limit, 429, exceeded quota

This means when Codex is unavailable, Claude Code typically gets feedback within seconds, not after a long timeout window.

### Failure Reporting Format

```
Codex [failure type]: [brief reason]

[Error details if available]

Options:
1. I'll handle this task myself
2. [Other recovery option]
3. Skip
```

**Key principle:** Let the user decide. Don't choose for them. Provide enough information for the user to make an informed judgment.

### Review Loop Failure Handling

| Situation | Action |
|-----------|--------|
| 3 review rounds failed | Stop loop. Report: completed parts + remaining issues + analysis |
| First timeout threshold during review | Keep waiting through the automatic grace window |
| Codex timeout during review | After the second timeout, read partial output and decide whether to retry, split, or take over |
| Codex fatal error during review | Claude Code takes over the fix instructions from the review |
| Resume fails | Start a new session instead of continuing to wait |
| Prior session timed out but a new task appears | Start a fresh session for the new task if it is independent |

### Takeover Principles

When Claude Code needs to take over Codex's unfinished work:
- **Read Codex's completed changes** (partial output in output_path may be useful)
- **Continue from existing progress**, don't start over
- **Explain takeover to user** (what failed + why taking over + plan)
- If Codex already modified files but didn't finish, run `git diff` to see existing changes first
- If the failed task was an internal Scout/Explore subtask, Claude Code may continue locally without surfacing the handoff unless the failure materially affects delivery
- Do not block unrelated new delegations behind the unfinished task; open a new Codex session when the next task is independent

### Timeout Recommendations

| Task Type | Recommended `--timeout` |
|-----------|------------------------|
| Scout / exploration / repo search | 600 |
| Data inspection / log triage | 600 |
| Simple file edits | 300 |
| Medium complexity implementation | 600 (default) |
| Large refactoring / multi-file | 900 |
| Code review (--read-only) | 600 |
| Debugging (--reasoning high) | 900 |

---

## How to Invoke

### ask_codex.sh (general invocation)

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh "Goal description" \
  --file <entry-file-1> \
  --file <entry-file-2>
```

### codex_broker.sh (live collaboration)

```bash
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh start "Goal description" \
  --file <entry-file-1> \
  --file <entry-file-2>
```

### With role parameters

```bash
# Scout
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --read-only \
  "Map where tenant IDs are derived and propagated. Summarize findings with file paths and command evidence." \
  --file src \
  --file app

# Writer (default)
~/.claude/skills/codex-delegator/scripts/ask_codex.sh "Implement feature..." --file src/main.ts

# Reviewer
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --read-only "Review changes..." --file src/main.ts

# Debugger
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --reasoning high "Fix bug..." --file src/buggy.ts

# Session reuse
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --session <sid> "Continue previous work..."

# Custom timeout
~/.claude/skills/codex-delegator/scripts/ask_codex.sh --timeout 900 --idle-timeout 240 "Complex refactoring task..."
```

### codex exec review (built-in code review)

For structured review of git changes, use Codex's built-in review command directly (bypasses ask_codex.sh):

```bash
# Review uncommitted changes
codex exec review --uncommitted --json "Focus on security vulnerabilities and logic errors"

# Review branch changes against main
codex exec review --base main --json "Check API compatibility"

# Review a specific commit
codex exec review --commit <sha> --json

# Custom review instructions from stdin
echo "Check for OWASP Top 10 security issues" | codex exec review --uncommitted --json -
```

**When to use `codex exec review` vs `ask_codex.sh --read-only`:**

| Scenario | Recommended |
|----------|-------------|
| Review git diff / commit / branch | `codex exec review` (purpose-built, normalized output) |
| Feasibility validation | `ask_codex.sh --read-only` (flexible) |
| Deep custom review (non-git scope) | `ask_codex.sh --read-only` (flexible) |

### Full Options Reference

| Option | Description |
|--------|-------------|
| `--file <path>` | Entry-point file (repeatable, 1–4) |
| `--session <id>` | Reuse a previous session |
| `--workspace <path>` | Working directory (default: current directory) |
| `--model <name>` | Model override |
| `--reasoning <level>` | Reasoning effort: low/medium/high (default: medium) |
| `--sandbox <mode>` | Sandbox policy override |
| `--read-only` | Read-only mode (for review/validation) |
| `--timeout <seconds>` | Total timeout window (default: 600s, 0 = no limit) |
| `--idle-timeout <seconds>` | Idle timeout without visible progress (default: 180s, 0 = no limit) |

### Output Format

On success:

```
session_id=<thread_id>
output_path=<path to markdown file>
```

Read `output_path` for Codex's response. Save `session_id` for follow-up `--session` calls.

---

## Integration with Existing Skills

| Scenario | Integration |
|----------|-------------|
| Large feature development | `writing-plans` creates plan → this skill delegates implementation tasks to Codex |
| Long notebook / script generation | Prefer broker mode so Claude Code can inspect progress and redirect mid-flight |
| Repo exploration / impact analysis | This skill should auto-trigger Mode 0 before Claude Code does a broad manual scan |
| Data and log investigation | Auto-delegate to Codex scout mode, then Claude Code synthesizes conclusions |
| Post-implementation verification | This skill's review loop + `verification-before-completion` for final check |
| Code review | This skill's cross-review mode + `requesting-code-review` format |
| Bug fixing | `systematic-debugging` locates root cause → this skill delegates fix to Codex |
| Parallel subtasks | `dispatching-parallel-agents` splits → this skill delegates in parallel |

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
