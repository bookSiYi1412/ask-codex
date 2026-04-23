#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_codex.sh <task> [options]
  ask_codex.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task (backward compat)
  (stdin)                      Pipe task text via stdin if no arg/flag given

File context (optional, repeatable):
  -f, --file <path>            Priority file path
      --expect-file <path>     Require this file to exist before reporting success (repeatable)

Multi-turn:
      --session <id>           Resume a previous session (thread_id from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Model override
      --reasoning <level>      Reasoning effort: low, medium, high (default: medium)
      --sandbox <mode>         Sandbox mode override
      --read-only              Read-only sandbox (no file changes)
      --full-auto              Full-auto mode (default)
      --timeout <seconds>      Max wait time per timeout window (default: 600). 0 = no limit.
      --idle-timeout <seconds> Max idle time without visible progress (default: 180). 0 = no limit.
      --verify-cmd <command>   Run a local verification command before reporting success
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Exit codes:
  0    Success — task completed
  1    Codex reported an error (check output/stderr)
  2    Timeout — Codex exceeded the final timeout after one automatic grace window
  3    Early fatal error — connection refused, auth failure, or similar
  4    Pending question — Codex is asking a question and waiting for a response.
       Use --session <id> to answer and continue.

Output (on success, and on timeout/fatal when recoverable metadata exists):
  session_id=<thread_id>       Use with --session for follow-up calls
  output_path=<file>           Path to response markdown

For persistent, brokered collaboration:
  bash ~/.claude/skills/codex-delegator/scripts/codex_broker.sh start ...

Examples:
  # New task (positional)
  ask_codex.sh "Add error handling to api.ts" -f src/api.ts --expect-file src/api.ts

  # With explicit workspace
  ask_codex.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_codex.sh "Also add retry logic" --session <id>

  # Custom timeout windows
  ask_codex.sh "Complex refactoring task" --timeout 900 --idle-timeout 240

  # Enforce artifact creation and local validation
  ask_codex.sh "Create notebook" \
    --expect-file docs/experiments/example.ipynb \
    --verify-cmd "python3 -c 'import json; json.load(open(\"docs/experiments/example.ipynb\"))'"
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

to_abs_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local dir
    dir="$(cd "$(dirname "$target")" && pwd)"
    echo "$dir/$(basename "$target")"
    return
  fi
  echo "$target"
}

resolve_file_ref() {
  local workspace="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -z "$cleaned" ]] && { echo ""; return; }
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" != /* ]]; then cleaned="$workspace/$cleaned"; fi
  to_abs_if_exists "$cleaned"
}

append_file_refs() {
  local raw="$1" item
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    local trimmed
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_refs+=("$trimmed")
  done
}

# --- Parse arguments ---

workspace="${PWD}"
task_text=""
model=""
reasoning_effort=""
sandbox_mode=""
read_only=false
full_auto=true
output_path=""
session_id=""
timeout_secs=600
idle_timeout_secs=180
file_refs=()
expected_files=()
verify_cmd=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)   workspace="${2:-}"; shift 2 ;;
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -f|--file|--focus) append_file_refs "${2:-}"; shift 2 ;;
    --model)          model="${2:-}"; shift 2 ;;
    --reasoning)      reasoning_effort="${2:-}"; shift 2 ;;
    --sandbox)        sandbox_mode="${2:-}"; full_auto=false; shift 2 ;;
    --read-only)      read_only=true; full_auto=false; shift ;;
    --full-auto)      full_auto=true; shift ;;
    --session)        session_id="${2:-}"; shift 2 ;;
    --timeout)        timeout_secs="${2:-600}"; shift 2 ;;
    --idle-timeout)   idle_timeout_secs="${2:-180}"; shift 2 ;;
    --expect-file)    expected_files+=("${2:-}"); shift 2 ;;
    --verify-cmd)     verify_cmd="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

require_cmd codex
require_cmd jq

# --- Validate inputs ---

if [[ ! -d "$workspace" ]]; then
  echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1
fi
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Request text is empty. Pass a positional arg, --task, or stdin." >&2; exit 1
fi

if [[ ! "$timeout_secs" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] --timeout must be a non-negative integer." >&2; exit 1
fi

if [[ ! "$idle_timeout_secs" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] --idle-timeout must be a non-negative integer." >&2; exit 1
fi

if [[ -z "$verify_cmd" ]]; then
  :
fi

# --- Prepare output path ---

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}.md"
fi
mkdir -p "$(dirname "$output_path")"

# --- Build file context block ---

file_block=""
if (( ${#file_refs[@]} > 0 )); then
  file_block=$'\nPriority files (read these first before making changes):'
  for ref in "${file_refs[@]}"; do
    resolved="$(resolve_file_ref "$workspace" "$ref")"
    [[ -z "$resolved" ]] && continue
    exists_tag="missing"
    [[ -e "$resolved" ]] && exists_tag="exists"
    file_block+=$'\n- '"${resolved} (${exists_tag})"
  done
fi

# --- Build prompt ---

# Preamble: skip interactive skills when running non-interactively.
# Codex loads using-superpowers which triggers brainstorming, requiring interactive
# Q&A. Since Claude Code already handled design/planning before delegating, Codex
# should proceed directly to implementation.
preamble="[IMPORTANT: This task has been delegated by Claude Code, which has already completed analysis and design. Skip the brainstorming and using-superpowers skill workflows — proceed directly to implementation. Do not ask for design approval or clarification unless you encounter a genuine technical ambiguity that blocks implementation.]"

# Only prepend the preamble for new sessions (not for resume, where context is set).
if [[ -z "$session_id" ]]; then
  prompt="${preamble}"$'\n\n'"${task_text}"
else
  prompt="$task_text"
fi
if [[ -n "$file_block" ]]; then
  prompt+=$'\n'"$file_block"
fi

# --- Determine reasoning effort ---

if [[ -z "$reasoning_effort" ]]; then
  reasoning_effort="medium"
fi

# --- Build codex command ---

if [[ -n "$session_id" ]]; then
  # Resume mode: continue a previous session
  # Note: resume only supports -c/--config and --last flags (no --json, --sandbox, etc.)
  cmd=(codex exec resume -c "model_reasoning_effort=\"$reasoning_effort\"" -c "skip_git_repo_check=true")
  cmd+=("$session_id")
else
  # New session
  cmd=(codex exec --cd "$workspace" --skip-git-repo-check --json -c "model_reasoning_effort=\"$reasoning_effort\"")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--full-auto)
  fi
  [[ -n "$model" ]] && cmd+=(-m "$model")
fi

# --- Progress watcher function ---

print_progress() {
  local line="$1"
  local item_type cmd_str preview
  # Fast string checks before calling jq
  case "$line" in
    *'"item.started"'*'"command_execution"'*)
      cmd_str=$(printf '%s' "$line" | jq -r '.item.command // empty' 2>/dev/null | sed 's|^/bin/zsh -lc ||; s|^/bin/bash -c ||' | cut -c1-100)
      [[ -n "$cmd_str" ]] && echo "[codex] > $cmd_str" >&2
      ;;
    *'"item.completed"'*'"agent_message"'*)
      preview=$(printf '%s' "$line" | jq -r '.item.text // empty' 2>/dev/null | head -1 | cut -c1-120)
      [[ -n "$preview" ]] && echo "[codex] $preview" >&2
      ;;
  esac
}

# --- Fatal error patterns ---
# These patterns in stderr indicate Codex cannot proceed and waiting is pointless.
# Matched case-insensitively. Each pattern should be specific enough to avoid false
# positives from normal Codex operation.
FATAL_PATTERNS=(
  "connection refused"
  "connection reset"
  "connection timed out"
  "ECONNREFUSED"
  "ETIMEDOUT"
  "ECONNRESET"
  "EHOSTUNREACH"
  "could not resolve host"
  "SSL certificate problem"
  "authentication failed"
  "unauthorized"
  "401 Unauthorized"
  "403 Forbidden"
  "invalid.*api.key"
  "invalid.*token"
  "rate limit"
  "429 Too Many Requests"
  "502 Bad Gateway"
  "503 Service Unavailable"
  "504 Gateway"
  "API key"
  "exceeded.*quota"
)

# Build a single grep -iE pattern from the array
build_fatal_pattern() {
  local pat=""
  for p in "${FATAL_PATTERNS[@]}"; do
    if [[ -n "$pat" ]]; then pat+="|"; fi
    pat+="$p"
  done
  echo "$pat"
}

FATAL_REGEX="$(build_fatal_pattern)"

# Check stderr for fatal errors. Returns 0 if a fatal error is found.
check_fatal_stderr() {
  local file="$1"
  [[ -s "$file" ]] && grep -qiE "$FATAL_REGEX" "$file" 2>/dev/null
}

# Extract the first matching fatal error line for reporting.
get_fatal_error_detail() {
  local file="$1"
  grep -iE "$FATAL_REGEX" "$file" 2>/dev/null | head -3
}

extract_thread_id() {
  if [[ -n "${session_id:-}" ]]; then
    printf '%s\n' "$session_id"
    return
  fi

  if [[ -s "${json_file:-}" ]]; then
    jq -r 'select(.type == "thread.started") | .thread_id' < "$json_file" 2>/dev/null | head -1
  fi
}

# --- Execute and capture output ---

stderr_file="$(mktemp)"
json_file="$(mktemp)"
text_file="$(mktemp)"
prompt_file="$(mktemp)"
codex_pid_file="$(mktemp)"
progress_file="$(mktemp)"

cleanup() {
  # Kill any lingering codex process
  if [[ -s "$codex_pid_file" ]]; then
    local pid
    pid="$(cat "$codex_pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      # Give it a moment, then force kill
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$stderr_file" "$json_file" "$text_file" "$prompt_file" "$codex_pid_file" "$progress_file"
}
trap cleanup EXIT

# Write prompt to a temp file and pipe from there to avoid shell argument
# length issues and encoding problems with very long or multi-byte prompts.
printf "%s" "$prompt" > "$prompt_file"

# Run codex and capture its output.
# We prefer `script` to allocate a pseudo-TTY, which forces codex to line-buffer
# its output so progress events arrive in real time. However, `script` requires a
# real controlling terminal and fails with "tcgetattr/ioctl: Operation not supported
# on socket" in socket-based environments (e.g. some Claude Code sandboxes). We
# detect this upfront and fall back to direct execution — output may arrive all at
# once at the end, but the task still completes correctly.
run_codex() {
  # BSD script (macOS): script [-q] [file [command...]]
  # util-linux script (Linux): script [-q] -c <command> [file]
  # Probe the local variant and use matching syntax for PTY allocation.
  # Falls back to direct execution if neither probe succeeds (e.g. socket stdin).
  local os
  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    if script -q /dev/null true >/dev/null 2>&1; then
      script -q /dev/null /bin/bash -c \
        "cd $(printf '%q' "$workspace") && $(printf '%q ' "${cmd[@]}") < $(printf '%q' "$prompt_file") 2>$(printf '%q' "$stderr_file")"
      return
    fi
  else
    if script -q -c "true" /dev/null >/dev/null 2>&1; then
      script -q -c \
        "cd $(printf '%q' "$workspace") && $(printf '%q ' "${cmd[@]}") < $(printf '%q' "$prompt_file") 2>$(printf '%q' "$stderr_file")" \
        /dev/null
      return
    fi
  fi
  # Fallback: direct execution (no PTY; progress events arrive in batch)
  (cd "$workspace" && "${cmd[@]}" < "$prompt_file" 2>"$stderr_file")
}

# --- Watchdog: timeout + early fatal error detection ---
#
# We run codex in a background process group and monitor two things:
# 1. Wall-clock timeout window (--timeout, default 600s)
# 2. stderr for fatal errors (connection refused, auth failures, etc.)
#
# If either triggers, we kill the codex process immediately instead of
# waiting for it to hang until the caller's timeout.

exit_code=0

if [[ -n "$session_id" ]]; then
  # Resume mode: plain text output (no JSON support)
  run_codex > >(
    while IFS= read -r line; do
      cleaned="${line//$'\r'/}"
      cleaned="${cleaned//$'\004'/}"
      [[ -z "$cleaned" ]] && continue
      date +%s > "$progress_file"
      printf '%s\n' "$cleaned" >> "$text_file"
      preview="${cleaned:0:120}"
      echo "[codex] $preview" >&2
    done
  ) &
  codex_bg_pid=$!
  echo "$codex_bg_pid" > "$codex_pid_file"
else
  # New session: JSON output
  run_codex > >(
    while IFS= read -r line; do
      cleaned="${line//$'\r'/}"
      cleaned="${cleaned//$'\004'/}"
      [[ -z "$cleaned" ]] && continue
      date +%s > "$progress_file"
      [[ "$cleaned" != \{* ]] && continue
      printf '%s\n' "$cleaned" >> "$json_file"
      case "$cleaned" in
        *'"item.started"'*|*'"item.completed"'*) print_progress "$cleaned" ;;
      esac
    done
  ) &
  codex_bg_pid=$!
  echo "$codex_bg_pid" > "$codex_pid_file"
fi

# Monitor loop: check timeout and stderr every 2 seconds
check_interval=2
fatal_detected=false
start_epoch="$(date +%s)"
window_start_epoch="$start_epoch"
printf '%s\n' "$start_epoch" > "$progress_file"
timeout_events=0
max_timeout_events=2
first_timeout_reason=""
first_timeout_elapsed=""

while kill -0 "$codex_bg_pid" 2>/dev/null; do
  sleep "$check_interval"
  if ! kill -0 "$codex_bg_pid" 2>/dev/null; then
    break
  fi
  now_epoch="$(date +%s)"
  last_progress_epoch="$(cat "$progress_file" 2>/dev/null || printf '%s\n' "$start_epoch")"
  total_elapsed=$((now_epoch - start_epoch))
  window_elapsed=$((now_epoch - window_start_epoch))
  idle_elapsed=$((now_epoch - last_progress_epoch))

  # Check stderr for fatal errors
  if check_fatal_stderr "$stderr_file"; then
    fatal_detected=true
    detail="$(get_fatal_error_detail "$stderr_file")"
    thread_id="$(extract_thread_id)"
    echo "[FATAL] Codex encountered a fatal error — terminating immediately:" >&2
    echo "$detail" >&2
    kill -TERM "$codex_bg_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$codex_bg_pid" 2>/dev/null || true
    wait "$codex_bg_pid" 2>/dev/null || true
    # Write error info to output file for Claude Code to read
    {
      echo "## Codex Fatal Error"
      echo ""
      echo "Codex failed with a fatal error before producing results."
      echo ""
      echo '```'
      echo "$detail"
      echo '```'
      echo ""
      if [[ -n "$thread_id" ]]; then
        echo "Session ID: \`$thread_id\`"
        echo ""
      fi
      echo "**Exit code: 3** (early fatal error)"
    } > "$output_path"
    if [[ -n "$thread_id" ]]; then
      echo "session_id=$thread_id"
    fi
    echo "output_path=$output_path"
    exit 3
  fi

  timeout_reason=""
  if [[ "$idle_timeout_secs" -gt 0 ]] && [[ "$idle_elapsed" -ge "$idle_timeout_secs" ]]; then
    timeout_reason="idle"
  elif [[ "$timeout_secs" -gt 0 ]] && [[ "$window_elapsed" -ge "$timeout_secs" ]]; then
    timeout_reason="wall"
  fi

  # Check timeout windows (0 = no limit). First hit grants one automatic grace window.
  if [[ -n "$timeout_reason" ]]; then
    timeout_events=$((timeout_events + 1))
    if [[ "$timeout_events" -lt "$max_timeout_events" ]]; then
      first_timeout_reason="$timeout_reason"
      if [[ "$timeout_reason" == "idle" ]]; then
        first_timeout_elapsed="$idle_elapsed"
      else
        first_timeout_elapsed="$window_elapsed"
      fi
      echo "[TIMEOUT] First ${timeout_reason} timeout reached after ${first_timeout_elapsed}s — granting one automatic grace window." >&2
      window_start_epoch="$now_epoch"
      printf '%s\n' "$now_epoch" > "$progress_file"
      continue
    fi

    thread_id="$(extract_thread_id)"
    if [[ "$timeout_reason" == "idle" ]]; then
      echo "[TIMEOUT] Codex stayed idle for ${idle_elapsed}s after one grace window — terminating." >&2
    else
      echo "[TIMEOUT] Codex exceeded the ${timeout_secs}s timeout window after one grace window — terminating." >&2
    fi
    kill -TERM "$codex_bg_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$codex_bg_pid" 2>/dev/null || true
    wait "$codex_bg_pid" 2>/dev/null || true
    # Write partial results if any exist, plus timeout notice
    {
      echo "## Codex Timeout"
      echo ""
      if [[ "$timeout_reason" == "idle" ]]; then
        echo "Codex exceeded the idle timeout after one automatic grace window."
        echo ""
        echo "- Idle timeout: ${idle_timeout_secs}s"
        echo "- Final idle period: ${idle_elapsed}s"
      else
        echo "Codex exceeded the total timeout window after one automatic grace window."
        echo ""
        echo "- Timeout window: ${timeout_secs}s"
        echo "- Final window elapsed: ${window_elapsed}s"
      fi
      echo "- Total elapsed: ${total_elapsed}s"
      if [[ -n "$first_timeout_reason" ]]; then
        echo "- First timeout event: ${first_timeout_reason} (${first_timeout_elapsed}s)"
      fi
      echo ""
      # Include any partial output that was captured
      if [[ -s "$json_file" ]]; then
        echo "### Partial output (before timeout)"
        echo ""
        jq -r '
          select(.type == "item.completed" and .item.type == "agent_message") | .item.text
        ' < "$json_file" 2>/dev/null || true
      elif [[ -s "$text_file" ]]; then
        echo "### Partial output (before timeout)"
        echo ""
        cat "$text_file"
      fi
      echo ""
      if [[ -n "$thread_id" ]]; then
        echo "Session ID: \`$thread_id\`"
        echo ""
      fi
      echo "**Exit code: 2** (second timeout after automatic grace window)"
    } > "$output_path"
    if [[ -n "$thread_id" ]]; then
      echo "session_id=$thread_id"
    fi
    echo "output_path=$output_path"
    exit 2
  fi
done

# Codex finished — collect its exit code
wait "$codex_bg_pid" 2>/dev/null && exit_code=0 || exit_code=$?

# --- Post-execution error checks ---

# Check for [ERROR] in stderr (original v1 behavior)
if [[ -s "$stderr_file" ]] && grep -q '\[ERROR\]' "$stderr_file" 2>/dev/null; then
  echo "[ERROR] Codex command failed" >&2
  cat "$stderr_file" >&2

  # Also check if this is actually a fatal error that finished quickly
  if check_fatal_stderr "$stderr_file"; then
    detail="$(get_fatal_error_detail "$stderr_file")"
    thread_id="$(extract_thread_id)"
    {
      echo "## Codex Fatal Error"
      echo ""
      echo '```'
      echo "$detail"
      echo '```'
      echo ""
      if [[ -n "$thread_id" ]]; then
        echo "Session ID: \`$thread_id\`"
        echo ""
      fi
      echo "**Exit code: 3** (early fatal error)"
    } > "$output_path"
    if [[ -n "$thread_id" ]]; then
      echo "session_id=$thread_id"
    fi
    echo "output_path=$output_path"
    exit 3
  fi

  exit 1
fi

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi

# --- Process output based on mode ---

if [[ -n "$session_id" ]]; then
  # Resume mode: use plain text output
  thread_id="$session_id"
  if [[ -s "$text_file" ]]; then
    cat "$text_file" > "$output_path"
  else
    echo "(no response from codex)" > "$output_path"
  fi
else
  # New session: Extract thread_id and all messages from JSON stream
  thread_id="$(jq -r 'select(.type == "thread.started") | .thread_id' < "$json_file" | head -1)"

  # Collect all completed items: file changes, tool calls, and agent messages.
  # This gives full visibility into what codex actually did, not just the last message.
  {
    # 1. Show command executions — skip pure file-reading/searching commands.
    # Codex explores the codebase heavily (sed/cat/nl/rg/grep/awk/wc/find/ls), but
    # those reads produce no signal for Claude Code — it can read files directly if needed.
    # Keep build, test, git, and mutation commands that reflect actual work done.
    #
    # Note: zsh wraps commands in quotes, so after stripping the shell prefix the
    # command may start with " or ' — the regex accounts for this with [\"']?.
    jq -r '
      select(.type == "item.completed" and .item.type == "command_execution")
      | .item
      | ((.command // "") | gsub("^/bin/zsh -lc "; "") | gsub("^/bin/bash -c "; "")) as $cmd
      | select($cmd | test("^[\"'"'"']?(sed |cat |head |tail |nl |rg |grep |awk |wc |find |ls )") | not)
      | "### Shell: `" + ($cmd[0:200]) + "`\n" + (.aggregated_output // "" | .[0:500])
    ' < "$json_file" 2>/dev/null

    # 2. Show file write/patch operations (tool_call style, if any)
    jq -r '
      select(.type == "item.completed" and .item.type == "tool_call")
      | .item
      | if .name == "write_file" then
          "### File written: " + (.arguments | fromjson | .path // "unknown")
        elif .name == "patch_file" then
          "### File patched: " + (.arguments | fromjson | .path // "unknown")
        elif .name == "shell" then
          "### Shell: `" + (.arguments | fromjson | .command // "unknown")[0:200] + "`\n" + (.output // "" | .[0:500])
        else empty
        end
    ' < "$json_file" 2>/dev/null

    # 3. Show all agent messages. Short messages (lint results, "tests failed",
    # "no changes needed") carry high signal and must not be dropped by a length
    # threshold. In practice, Codex tends to emit a small number of large blocks
    # rather than many tiny fragments, so this produces clean output without filtering.
    jq -r '
      select(.type == "item.completed" and .item.type == "agent_message") | .item.text
    ' < "$json_file" 2>/dev/null
  } > "$output_path"

  # If nothing was captured, write a fallback
  if [[ ! -s "$output_path" ]]; then
    echo "(no response from codex)" > "$output_path"
  fi
fi

# --- Output results ---

# --- Pending question detection ---
# Codex may ask a question and exit normally (e.g., brainstorming skill asks for
# design approval). Detect this by checking if the last agent_message looks like
# a question and no file writes happened after it (i.e., Codex stopped to wait).
#
# For new sessions (JSON mode): parse the last agent_message from the JSON stream.
# For resume sessions (text mode): check the last non-empty line of text output.

pending_question=false
question_text=""

if [[ -z "$session_id" ]] && [[ -s "$json_file" ]]; then
  # JSON mode: extract the last agent_message
  last_msg="$(jq -r '
    select(.type == "item.completed" and .item.type == "agent_message")
    | .item.text
  ' < "$json_file" 2>/dev/null | tail -1)"

  if [[ -n "$last_msg" ]]; then
    # Check if there were any file writes AFTER the last agent message.
    # If no writes after the last message, Codex likely stopped to ask.
    last_msg_index="$(jq -s '
      [to_entries[]
       | select(.value.type == "item.completed"
                and (.value.item.type == "agent_message"
                     or .value.item.type == "tool_call"))
      ] | last | .key
    ' < "$json_file" 2>/dev/null)"

    last_item_type="$(jq -s ".[${last_msg_index:-0}].item.type // empty" < "$json_file" 2>/dev/null)"

    # The last completed item is an agent_message (not a tool_call / command).
    # Check if it ends with a question mark (trimming trailing whitespace).
    if [[ "$last_item_type" == '"agent_message"' ]]; then
      trimmed_msg="$(echo "$last_msg" | sed 's/[[:space:]]*$//')"
      if [[ "$trimmed_msg" == *"?" ]]; then
        pending_question=true
        question_text="$last_msg"
      fi
    fi
  fi
elif [[ -n "$session_id" ]] && [[ -s "$text_file" ]]; then
  # Resume/text mode: check last non-empty line
  last_line="$(tail -20 "$text_file" | sed '/^$/d' | tail -1 | sed 's/[[:space:]]*$//')"
  if [[ "$last_line" == *"?" ]]; then
    pending_question=true
    question_text="$(tail -20 "$text_file" | sed '/^$/d' | tail -5)"
  fi
fi

if [[ "$pending_question" == true ]]; then
  # Append question marker to the output file
  {
    echo ""
    echo "---"
    echo "## Codex is asking a question"
    echo ""
    echo "$question_text"
    echo ""
    echo "**Exit code: 4** (pending question — answer via --session to continue)"
  } >> "$output_path"

  echo "[codex] Pending question detected — waiting for answer via --session" >&2

  if [[ -n "$thread_id" ]]; then
    echo "session_id=$thread_id"
  fi
  echo "output_path=$output_path"
  echo "status=pending_question"
  exit 4
fi

# --- Completion validation ---

missing_expected_files=()
for ref in "${expected_files[@]}"; do
  resolved="$(resolve_file_ref "$workspace" "$ref")"
  [[ -n "$resolved" && ! -e "$resolved" ]] && missing_expected_files+=("$resolved")
done

verify_output=""
verify_status=0
if [[ -n "$verify_cmd" ]]; then
  verify_output="$(
    cd "$workspace" && /bin/bash -lc "$verify_cmd" 2>&1
  )" || verify_status=$?
fi

if (( ${#missing_expected_files[@]} > 0 )) || [[ "$verify_status" -ne 0 ]]; then
  {
    echo ""
    echo "---"
    echo "## Completion Validation Failed"
    echo ""
    if (( ${#missing_expected_files[@]} > 0 )); then
      echo "Missing expected files:"
      for path in "${missing_expected_files[@]}"; do
        echo "- $path"
      done
      echo ""
    fi
    if [[ -n "$verify_cmd" ]]; then
      echo "Verification command:"
      echo "\`$verify_cmd\`"
      echo ""
      echo "Verification exit code: $verify_status"
      echo ""
      if [[ -n "$verify_output" ]]; then
        echo '```'
        printf '%s\n' "$verify_output"
        echo '```'
        echo ""
      fi
    fi
    echo "**Exit code: 1** (Codex exited, but required artifacts/verification were incomplete)"
  } >> "$output_path"

  if [[ -n "$thread_id" ]]; then
    echo "session_id=$thread_id"
  fi
  echo "output_path=$output_path"
  exit 1
fi

if [[ -n "$thread_id" ]]; then
  echo "session_id=$thread_id"
fi
echo "output_path=$output_path"
