# Failure Recovery Strategy

The script uses differentiated exit codes. Claude Code should choose the recovery path based on exit code.

## Exit Code Reference

| Exit Code | Meaning | Typical Cause |
|-----------|---------|---------------|
| **0** | Success | Codex completed normally |
| **1** | Codex error | Error during execution (stderr contains `[ERROR]`) |
| **2** | Timeout | Exceeded the final timeout after one automatic grace window |
| **3** | Early fatal error | Connection failure, auth error, API unavailable |
| **4** | Pending question | Codex is asking a question (e.g., brainstorming confirmation) |
| **137** | OOM / killed | Out of memory or killed by external signal |

## Multi-Turn Relay Protocol (exit code 4)

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
output=$(~/.claude/skills/ask-codex/scripts/ask_codex.sh "Add pagination to UserList" --file src/UserList.tsx)
# exit code 4 — Codex asks: "Should pagination be client-side or server-side?"

sid=$(echo "$output" | grep "^session_id=" | cut -d= -f2)

# Claude Code answers and continues
output=$(~/.claude/skills/ask-codex/scripts/ask_codex.sh --session "$sid" \
  "Server-side pagination. The API already supports ?page=N&limit=20 parameters.")
# exit code 0 — done
```

**Key rules for the relay:**
- Claude Code answers on behalf of the user, using context from the current conversation
- If Claude Code cannot confidently answer, ask the user before responding to Codex
- Max 5 relay rounds per task; if exceeded, report to user with conversation history
- Each relay answer should be concise and decisive — Codex needs clear direction, not discussion

## Recovery Decision Tree

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

## Fast Fatal Error Detection

The script monitors stderr in real-time and **immediately terminates Codex with exit 3** upon detecting these patterns (instead of waiting for timeout):

- **Connection:** connection refused/reset/timed out, ECONNREFUSED, ETIMEDOUT
- **Auth:** authentication failed, unauthorized, 401/403, invalid api key/token
- **Service:** 502/503/504, rate limit, 429, exceeded quota

This means when Codex is unavailable, Claude Code typically gets feedback within seconds, not after a long timeout window.

## Failure Reporting Format

```
Codex [failure type]: [brief reason]

[Error details if available]

Options:
1. I'll handle this task myself
2. [Other recovery option]
3. Skip
```

**Key principle:** Let the user decide. Don't choose for them. Provide enough information for the user to make an informed judgment.

## Review Loop Failure Handling

| Situation | Action |
|-----------|--------|
| 3 review rounds failed | Stop loop. Report: completed parts + remaining issues + analysis |
| First timeout threshold during review | Keep waiting through the automatic grace window |
| Codex timeout during review | After the second timeout, read partial output and decide whether to retry, split, or take over |
| Codex fatal error during review | Claude Code takes over the fix instructions from the review |
| Resume fails | Start a new session instead of continuing to wait |
| Prior session timed out but a new task appears | Start a fresh session for the new task if it is independent |

## Takeover Principles

When Claude Code needs to take over Codex's unfinished work:

- **Read Codex's completed changes** (partial output in output_path may be useful)
- **Continue from existing progress**, don't start over
- **Explain takeover to user** (what failed + why taking over + plan)
- If Codex already modified files but didn't finish, run `git diff` to see existing changes first
- If the failed task was an internal Scout/Explore subtask, Claude Code may continue locally without surfacing the handoff unless the failure materially affects delivery
- Do not block unrelated new delegations behind the unfinished task; open a new Codex session when the next task is independent
