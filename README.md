# Ask Codex

Ask Codex is an unofficial Claude Code skill that helps Claude Code delegate repository work to the Codex CLI. It provides routing guidance, single-turn delegation, brokered multi-turn sessions, and review-loop conventions for collaboration between Claude Code and Codex.

This project is not affiliated with or endorsed by Anthropic or OpenAI.

Chinese documentation: [README.zh-CN.md](README.zh-CN.md)

## What It Does

- Routes implementation, exploration, verification, and review-heavy work from Claude Code to Codex.
- Provides `ask_codex.sh` for one-shot Codex delegation.
- Provides `codex_broker.sh` for long-running or interactive Codex sessions.
- Includes a Windows PowerShell helper, `ask_codex.ps1`.
- Keeps Claude Code responsible for user interaction, scope control, and final verification.

## Requirements

- Claude Code with skill support.
- Codex CLI installed, authenticated, and available as `codex`.
- `jq`.
- Bash for `scripts/ask_codex.sh` and `scripts/codex_broker.sh`.
- PowerShell 5.1+ for `scripts/ask_codex.ps1` on Windows.

## Installation

Recommended installation with the `skills` CLI:

```bash
npx skills add bookSiYi1412/ask-codex -g -a claude-code
```

Manual installation:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/bookSiYi1412/ask-codex ~/.claude/skills/ask-codex
chmod +x ~/.claude/skills/ask-codex/scripts/*.sh
```

Restart Claude Code if needed so the skill metadata is reloaded.

## Skill Name

The skill is named `ask-codex`.

Claude Code should trigger it when a task involves implementation work, repository exploration, data or log inspection, broad codebase search, impact analysis, verification-heavy shell work, or explicit requests to use Codex.

## Claude Code Usage Examples

Use the skill explicitly when you want Claude Code to delegate work to Codex.

Simple implementation task:

```text
/ask-codex Implement pagination for the user list. Keep the existing filters and add tests.
```

Read-only repository exploration:

```text
/ask-codex Find where tenant IDs are derived and propagated. Do not modify files. Summarize findings with file paths and command evidence.
```

Parallel implementation tasks:

```text
/ask-codex Run two independent Codex tasks in parallel:
1. Write docs/code_architecture.md explaining the module structure, data flow, and evaluation design.
2. Write docs/quickstart_guide.md with step-by-step setup and experiment-running instructions.

Review both outputs after Codex finishes and report quality issues before finalizing.
```

Long-running guided work:

```text
/ask-codex Use a brokered Codex session to implement the migration. Monitor progress, send follow-up instructions if needed, then review the final diff.
```

Tip: when a Codex task is running in the foreground inside Claude Code, press `Ctrl+B` to move it to the background so you can keep working while it runs.

## Direct Script Usage

One-shot delegation:

```bash
~/.claude/skills/ask-codex/scripts/ask_codex.sh \
  "Add error handling to api.ts" \
  --file src/api.ts
```

Read-only exploration:

```bash
~/.claude/skills/ask-codex/scripts/ask_codex.sh \
  --read-only \
  "Find all call sites for the tenant ID derivation logic"
```

Brokered session:

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh start \
  "Implement the requested change" \
  --file src/main.ts
```

Check broker status:

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh status <broker_id>
```

Send follow-up instructions:

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh send <broker_id> \
  "Also add validation for the new input."
```

## Runtime Files

The scripts may create local runtime artifacts:

- `.runtime/`
- `.sessions/`

These files can contain prompts, model responses, repository paths, and task details. They are ignored by Git and should not be published.

## Verification

Run lightweight syntax checks before publishing changes:

```bash
scripts/check.sh
```

The check script runs Bash syntax checks and uses `shellcheck` when it is installed.

## Origins and Attribution

This project is based on and substantially extends [`oil-oil/codex`](https://github.com/oil-oil/codex), a Claude Code skill for delegating coding tasks to Codex CLI.

Major additions in this repository include expanded routing guidance, brokered session support, additional failure handling, open-source project documentation, and release-oriented maintenance files. See [NOTICE](NOTICE) for attribution details.

## License

Apache License 2.0. See [LICENSE](LICENSE).
