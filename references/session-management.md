# Role-Based Session Management

For ongoing projects, maintain named-role Codex sessions, similar to the `/agents` pattern.

## Role Definitions

| Role | Launch Parameters | Purpose |
|------|-------------------|---------|
| **scout** | `--read-only` (often `--reasoning low` or `medium`) | Repo exploration, data inspection, impact mapping, evidence gathering |
| **writer** | (default full-auto) | Code implementation, feature development |
| **reviewer** | `--read-only` or `codex exec review` | Code review, feasibility validation |
| **debugger** | `--reasoning high` | Bug diagnosis and fixes |

For the reviewer role, see `references/invocation.md` for when to pick `codex exec review` vs `ask_codex.sh --read-only`.

## Session Lifecycle

```
1. Brokered flow: create a broker_id first, then let the broker discover / persist the Codex session_id
2. Same broker session → use `send` to queue follow-ups instead of starting a fresh task blindly
3. Same-role follow-up without broker → `--session <id>` reuse (preserve context)
4. Role type change → new session (resume doesn't support switching --read-only etc.)
5. Session invalid (not in git repo, errors) → new session, don't force resume
6. Session timed out on one task → treat that task as stalled, not Codex globally blocked
7. New independent task after a timeout → feel free to open a fresh session immediately
```

## Timeout and New-Task Policy

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

## Resume Limitations

`--session` resume has these limitations (script handles them, but callers should be aware):

- Must be in a git repository
- Cannot switch `--sandbox`, `--read-only`, `--model`
- Output is plain text (not JSON)

When switching from writer to reviewer (requires `--read-only`), a new session is required.

## Timeout Recommendations by Task Type

| Task Type | Recommended `--timeout` |
|-----------|------------------------|
| Scout / exploration / repo search | 600 |
| Data inspection / log triage | 600 |
| Simple file edits | 300 |
| Medium complexity implementation | 600 (default) |
| Large refactoring / multi-file | 900 |
| Code review (--read-only) | 600 |
| Debugging (--reasoning high) | 900 |
