# Invocation Reference

Detailed command-line reference for the scripts and Codex built-ins this skill coordinates. SKILL.md has the minimal commands you need for the common path; this file has the full option surface and integration notes.

## ask_codex.sh — general invocation

```bash
~/.claude/skills/ask-codex/scripts/ask_codex.sh "Goal description" \
  --file <entry-file-1> \
  --file <entry-file-2>
```

### With role parameters

```bash
# Scout
~/.claude/skills/ask-codex/scripts/ask_codex.sh --read-only \
  "Map where tenant IDs are derived and propagated. Summarize findings with file paths and command evidence." \
  --file src \
  --file app

# Writer (default)
~/.claude/skills/ask-codex/scripts/ask_codex.sh "Implement feature..." --file src/main.ts

# Reviewer
~/.claude/skills/ask-codex/scripts/ask_codex.sh --read-only "Review changes..." --file src/main.ts

# Debugger
~/.claude/skills/ask-codex/scripts/ask_codex.sh --reasoning high "Fix bug..." --file src/buggy.ts

# Session reuse
~/.claude/skills/ask-codex/scripts/ask_codex.sh --session <sid> "Continue previous work..."

# Custom timeout
~/.claude/skills/ask-codex/scripts/ask_codex.sh --timeout 900 --idle-timeout 240 "Complex refactoring task..."
```

### Full Options

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

## codex_broker.sh — live collaboration

```bash
# Start a brokered session
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh start "Goal description" \
  --file <entry-file-1> \
  --file <entry-file-2>

# Inspect current state
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh status <broker_id>

# Queue a follow-up
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh send <broker_id> "Also add validation."

# Interrupt and redirect
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh send <broker_id> "Change direction..." --interrupt

# Wait for queue drain
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh wait <broker_id> --timeout 600

# Stop the broker
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh stop <broker_id>
```

See `references/collaboration-modes.md` for the brokered collaboration mode (Mode F) details.

## codex exec review — built-in code review

For structured review of git changes, use Codex's built-in `review` command directly (bypasses `ask_codex.sh`):

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

### When to use `codex exec review` vs `ask_codex.sh --read-only`

| Scenario | Recommended |
|----------|-------------|
| Review git diff / commit / branch | `codex exec review` (purpose-built, normalized output) |
| Feasibility validation | `ask_codex.sh --read-only` (flexible) |
| Deep custom review (non-git scope) | `ask_codex.sh --read-only` (flexible) |

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
