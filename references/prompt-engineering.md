# Prompt Engineering Guide

Codex output quality depends heavily on prompt design. These principles are distilled from 22 real-world runs analyzing success/failure patterns.

## Core Principles

### 1. Verification Gates (the single most impactful optimization)

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

### 2. Structured Constraints Over Narrative

List constraints as bullet points in the prompt body. Codex frequently misses constraints buried in paragraphs.

```
✗ "Note that this project uses React 18, and we have a convention that all state
   management uses zustand not redux, also component filenames use PascalCase..."

✓ Constraints:
  - React 18 (do not use deprecated APIs)
  - State management: zustand only, not redux
  - Component filenames: PascalCase
```

### 3. Goal-Driven, Not Step-by-Step

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

### 4. Entry File Strategy

- **Use `--file` for 1–4 entry-point files.** Codex will discover related files on its own from these starting points.
- **Choose the most relevant entries**, don't enumerate everything possibly related.
- **Never paste file contents into the prompt** — `--file` lets Codex read the current version directly, avoiding token waste and version staleness.

### 5. Single Responsibility

One prompt, one job. Don't combine review, implementation, and documentation in a single prompt.

```
✗ "Review this code, fix issues found, then update the docs"
✓ Three separate calls: review → implement fixes → update docs
```

Runtime data shows: prompts mixing 3+ goals see ~40% quality drop, while single-responsibility long tasks (20K+ output) produce the highest quality.

### 6. Leverage Codex's Built-in Skills and AGENTS.md

Codex automatically reads `AGENTS.md` files from the project root. If the project already has an AGENTS.md, don't repeat project conventions in the prompt. Codex also has its own installed skills (e.g., TDD, brainstorming) — if the project's AGENTS.md references these, Codex will follow them automatically.

## Prompt Templates by Task Type

### Scout / Exploration (Mode 0)

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

### Implementation (Modes A/B/C)

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

### TDD Implementation (highest-quality pattern)

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

### Code Review

For structured review of git changes, prefer Codex's built-in `review` subcommand (see `references/invocation.md`). For deeper custom review (e.g., feasibility validation), use `ask_codex.sh --read-only`:

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

### Debugging (with `--reasoning high`)

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

### Feasibility Validation (Mode D, with `--read-only`)

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

## Prompt Anti-Patterns (Lessons Learned)

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

## Context Transfer Strategy

Claude Code's analysis-phase insights should be efficiently transferred to Codex:

| Information Type | Transfer Method | Notes |
|-----------------|----------------|-------|
| Entry-point files | `--file` | Most efficient; Codex reads the current version directly |
| Root cause analysis | Prompt body | Distill to 2–3 sentences of conclusions, not the analysis process |
| Existing code style | `--file` pointing to example | "Follow the style of tests/test_auth.py" |
| Technical constraints | Prompt bullet list | Must be explicit in the prompt body |
| Project conventions | AGENTS.md (automatic) | If project has AGENTS.md, don't repeat |
| Large code context | Don't transfer | Codex has its own exploration tools; let it read |

## Verification Requirement Templates

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
