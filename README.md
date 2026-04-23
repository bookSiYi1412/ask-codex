# Ask Codex

Ask Codex is an unofficial Claude Code skill that helps Claude Code delegate repository work to the Codex CLI. It provides routing guidance, single-turn delegation, brokered multi-turn sessions, and review-loop conventions for collaboration between Claude Code and Codex.

This project is not affiliated with or endorsed by Anthropic or OpenAI.

## Origins and Attribution

This project is based on and substantially extends [`oil-oil/codex`](https://github.com/oil-oil/codex), a Claude Code skill for delegating coding tasks to Codex CLI.

Major additions in this repository include expanded routing guidance, brokered session support, additional failure handling, open-source project documentation, and release-oriented maintenance files. See [NOTICE](NOTICE) for attribution details.

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

Clone this repository into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/<your-name>/ask-codex ~/.claude/skills/codex-delegator
chmod +x ~/.claude/skills/codex-delegator/scripts/*.sh
```

Restart Claude Code if needed so the skill metadata is reloaded.

## Skill Name

The skill is named `codex-delegator`.

Claude Code should trigger it when a task involves implementation work, repository exploration, data or log inspection, broad codebase search, impact analysis, verification-heavy shell work, or explicit requests to use Codex.

## Direct Script Usage

One-shot delegation:

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh \
  "Add error handling to api.ts" \
  --file src/api.ts
```

Read-only exploration:

```bash
~/.claude/skills/codex-delegator/scripts/ask_codex.sh \
  --read-only \
  "Find all call sites for the tenant ID derivation logic"
```

Brokered session:

```bash
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh start \
  "Implement the requested change" \
  --file src/main.ts
```

Check broker status:

```bash
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh status <broker_id>
```

Send follow-up instructions:

```bash
bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh send <broker_id> \
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

## License

Apache License 2.0. See [LICENSE](LICENSE).
