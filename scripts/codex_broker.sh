#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
skill_dir="$(cd "$script_dir/.." && pwd)"
session_root="${CODEX_BROKER_SESSION_ROOT:-$skill_dir/.sessions}"
ask_script="${ASK_CODEX_SCRIPT:-$script_dir/ask_codex.sh}"

usage() {
  cat <<'USAGE'
Usage:
  codex_broker.sh start <task> [options]
  codex_broker.sh send <broker_id> <message> [--interrupt]
  codex_broker.sh status <broker_id> [--json]
  codex_broker.sh summary <broker_id>
  codex_broker.sh wait <broker_id> [--timeout <seconds>]
  codex_broker.sh logs <broker_id> [--follow]
  codex_broker.sh stop <broker_id>

Commands:
  start                 Start or queue the initial Codex turn in a persistent broker session
  send                  Queue a follow-up message for an existing broker session
  status                Show current state, latest progress, and pending queue depth
  summary               Print a concise human-readable summary of the session state
  wait                  Wait until the session is no longer running
  logs                  Show broker activity log (optionally follow)
  stop                  Stop the broker worker and the current Codex turn

Start options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Model override
      --reasoning <level>      Reasoning effort: low, medium, high (default: medium)
      --sandbox <mode>         Sandbox mode override
      --read-only              Read-only sandbox (no file changes)
      --full-auto              Full-auto mode (default)
      --timeout <seconds>      Timeout window passed to ask_codex.sh (default: 600)
      --idle-timeout <seconds> Idle timeout passed to ask_codex.sh (default: 180)
  -f, --file <path>            Priority file path (repeatable)
      --name <label>           Optional human label for the broker session

Send options:
      --interrupt              Stop the current Codex turn before processing this message

Status options:
      --json                   Print machine-readable JSON

Wait options:
      --timeout <seconds>      Max time to wait (default: 0 = no limit)

Notes:
  - A broker session keeps a worker process alive and reuses the same Codex session id across turns.
  - While a turn is running, `send` queues the next instruction. With `--interrupt`, the current turn
    is terminated and the queued instruction becomes the next turn.
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

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

session_dir_for() {
  printf '%s/%s\n' "$session_root" "$1"
}

state_file_for() {
  printf '%s/state.json\n' "$(session_dir_for "$1")"
}

activity_log_for() {
  printf '%s/activity.log\n' "$(session_dir_for "$1")"
}

latest_output_for() {
  printf '%s/latest.md\n' "$(session_dir_for "$1")"
}

queue_dir_for() {
  printf '%s/queue\n' "$(session_dir_for "$1")"
}

runs_dir_for() {
  printf '%s/runs\n' "$(session_dir_for "$1")"
}

update_state() {
  local broker_id="$1"
  local filter="$2"
  local state_file tmp
  state_file="$(state_file_for "$broker_id")"
  tmp="$(mktemp)"
  jq "$filter" "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

update_state_args() {
  local broker_id="$1"
  shift
  local state_file tmp
  state_file="$(state_file_for "$broker_id")"
  tmp="$(mktemp)"
  jq "$@" "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

log_activity() {
  local broker_id="$1"
  shift
  printf '%s %s\n' "$(now_iso)" "$*" >> "$(activity_log_for "$broker_id")"
}

append_event() {
  local broker_id="$1"
  local event_type="$2"
  local payload="${3-}"
  [[ -n "$payload" ]] || payload='{}'
  local event_file
  event_file="$(session_dir_for "$broker_id")/events.jsonl"
  jq -cn \
    --arg ts "$(now_iso)" \
    --arg type "$event_type" \
    --argjson payload "$payload" \
    '{timestamp:$ts, type:$type, payload:$payload}' >> "$event_file"
}

next_queue_file() {
  local qdir="$1"
  find "$qdir" -maxdepth 1 -type f -name '*.json' | sort | head -1
}

queue_count() {
  local qdir="$1"
  find "$qdir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '
}

enqueue_message() {
  local broker_id="$1"
  local message="$2"
  local interrupt="${3:-false}"
  local qdir file
  qdir="$(queue_dir_for "$broker_id")"
  mkdir -p "$qdir"
  file="$qdir/$(date -u +%Y%m%d-%H%M%S)-$$-$RANDOM.json"
  jq -cn \
    --arg ts "$(now_iso)" \
    --arg msg "$message" \
    --argjson interrupt "$interrupt" \
    '{created_at:$ts, message:$msg, interrupt:$interrupt}' > "$file"
}

resolve_state_value() {
  local broker_id="$1"
  local filter="$2"
  jq -r "$filter" "$(state_file_for "$broker_id")"
}

initialize_session() {
  local broker_id="$1"
  local session_dir="$2"
  local workspace="$3"
  local name="$4"
  local model="$5"
  local reasoning="$6"
  local sandbox_mode="$7"
  local read_only="$8"
  local full_auto="$9"
  local timeout_secs="${10}"
  local idle_timeout_secs="${11}"
  shift 11
  local -a file_refs=("$@")
  local file_refs_json="[]"
  if (( ${#file_refs[@]} > 0 )); then
    file_refs_json="$(printf '%s\n' "${file_refs[@]}" | jq -R . | jq -s .)"
  fi

  mkdir -p "$session_dir" "$(queue_dir_for "$broker_id")" "$(runs_dir_for "$broker_id")"
  : > "$(activity_log_for "$broker_id")"

  jq -cn \
    --arg broker_id "$broker_id" \
    --arg session_dir "$session_dir" \
    --arg name "$name" \
    --arg workspace "$workspace" \
    --arg model "$model" \
    --arg reasoning "$reasoning" \
    --arg sandbox_mode "$sandbox_mode" \
    --argjson read_only "$read_only" \
    --argjson full_auto "$full_auto" \
    --argjson timeout_secs "$timeout_secs" \
    --argjson idle_timeout_secs "$idle_timeout_secs" \
    --arg started_at "$(now_iso)" \
    --arg updated_at "$(now_iso)" \
    --argjson file_refs "$file_refs_json" \
    '{
      broker_id:$broker_id,
      session_dir:$session_dir,
      name:$name,
      workspace:$workspace,
      model:$model,
      reasoning:$reasoning,
      sandbox_mode:$sandbox_mode,
      read_only:$read_only,
      full_auto:$full_auto,
      timeout_secs:$timeout_secs,
      idle_timeout_secs:$idle_timeout_secs,
      file_refs:$file_refs,
      status:"starting",
      last_run_status:"none",
      worker_pid:null,
      current_pid:null,
      session_id:null,
      current_run_dir:null,
      current_message:null,
      last_output_path:null,
      last_exit_code:null,
      pending_count:0,
      latest_progress:"",
      latest_summary:"",
      started_at:$started_at,
      updated_at:$updated_at
    }' > "$session_dir/state.json"
}

spawn_worker() {
  local broker_id="$1"
  local session_dir
  session_dir="$(session_dir_for "$broker_id")"
  mkdir -p "$session_root"
  /bin/bash "$script_self" __worker "$session_dir" >/dev/null 2>&1 &
  local worker_pid=$!
  update_state_args "$broker_id" \
    --argjson worker_pid "$worker_pid" \
    --arg updated_at "$(now_iso)" \
    '.worker_pid = $worker_pid | .updated_at = $updated_at | .status = "queued"'
}

tail_excerpt() {
  local path="$1"
  local lines="${2:-20}"
  if [[ -f "$path" ]]; then
    tail -n "$lines" "$path"
  fi
}

ensure_session_exists() {
  local broker_id="$1"
  if [[ ! -f "$(state_file_for "$broker_id")" ]]; then
    echo "[ERROR] Unknown broker session: $broker_id" >&2
    exit 1
  fi
}

handle_start() {
  local workspace="${PWD}"
  local task=""
  local model=""
  local reasoning="medium"
  local sandbox_mode=""
  local read_only=false
  local full_auto=true
  local timeout_secs=600
  local idle_timeout_secs=180
  local name=""
  local -a file_refs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -w|--workspace) workspace="${2:-}"; shift 2 ;;
      -f|--file|--focus) file_refs+=("${2:-}"); shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --reasoning) reasoning="${2:-medium}"; shift 2 ;;
      --sandbox) sandbox_mode="${2:-}"; full_auto=false; shift 2 ;;
      --read-only) read_only=true; full_auto=false; shift ;;
      --full-auto) full_auto=true; shift ;;
      --timeout) timeout_secs="${2:-600}"; shift 2 ;;
      --idle-timeout) idle_timeout_secs="${2:-180}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      -*) echo "[ERROR] Unknown option for start: $1" >&2; exit 1 ;;
      *) if [[ -z "$task" ]]; then task="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; exit 1; fi ;;
    esac
  done

  task="$(trim_whitespace "$task")"
  [[ -n "$task" ]] || { echo "[ERROR] start requires an initial task." >&2; exit 1; }
  [[ -d "$workspace" ]] || { echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1; }
  workspace="$(cd "$workspace" && pwd)"

  local broker_id session_dir
  broker_id="$(date -u +%Y%m%d-%H%M%S)-$$-$RANDOM"
  session_dir="$(session_dir_for "$broker_id")"

  initialize_session "$broker_id" "$session_dir" "$workspace" "$name" "$model" "$reasoning" "$sandbox_mode" "$read_only" "$full_auto" "$timeout_secs" "$idle_timeout_secs" "${file_refs[@]}"
  enqueue_message "$broker_id" "$task" false
  update_state_args "$broker_id" \
    --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
    --arg updated_at "$(now_iso)" \
    '.pending_count = $pending | .updated_at = $updated_at | .status = "queued"'
  log_activity "$broker_id" "Broker session created"
  append_event "$broker_id" "session_started" '{}'
  spawn_worker "$broker_id"

  printf 'broker_id=%s\n' "$broker_id"
  printf 'session_dir=%s\n' "$session_dir"
  printf 'status=%s\n' "queued"
}

worker_run_turn() {
  local session_dir="$1"
  local broker_id
  broker_id="$(basename "$session_dir")"
  local qfile payload message interrupt
  qfile="$(next_queue_file "$(queue_dir_for "$broker_id")")"
  [[ -n "$qfile" ]] || return 1
  payload="$(cat "$qfile")"
  message="$(jq -r '.message' <<<"$payload")"
  interrupt="$(jq -r '.interrupt' <<<"$payload")"

  local run_id run_dir stdout_file stderr_file output_file
  run_id="$(date -u +%Y%m%d-%H%M%S)-$RANDOM"
  run_dir="$(runs_dir_for "$broker_id")/$run_id"
  stdout_file="$run_dir/stdout.txt"
  stderr_file="$run_dir/stderr.txt"
  output_file="$run_dir/output.md"
  mkdir -p "$run_dir"

  local workspace model reasoning sandbox_mode read_only full_auto timeout_secs idle_timeout_secs session_id
  workspace="$(resolve_state_value "$broker_id" '.workspace')"
  model="$(resolve_state_value "$broker_id" '.model // ""')"
  reasoning="$(resolve_state_value "$broker_id" '.reasoning // "medium"')"
  sandbox_mode="$(resolve_state_value "$broker_id" '.sandbox_mode // ""')"
  read_only="$(resolve_state_value "$broker_id" '.read_only')"
  full_auto="$(resolve_state_value "$broker_id" '.full_auto')"
  timeout_secs="$(resolve_state_value "$broker_id" '.timeout_secs')"
  idle_timeout_secs="$(resolve_state_value "$broker_id" '.idle_timeout_secs')"
  session_id="$(resolve_state_value "$broker_id" '.session_id // empty')"

  local -a cmd file_refs
  mapfile -t file_refs < <(jq -r '.file_refs[]?' "$(state_file_for "$broker_id")")
  cmd=("$ask_script")
  [[ -n "$workspace" ]] && cmd+=(-w "$workspace")
  [[ -n "$model" ]] && cmd+=(--model "$model")
  [[ -n "$reasoning" ]] && cmd+=(--reasoning "$reasoning")
  [[ -n "$sandbox_mode" ]] && cmd+=(--sandbox "$sandbox_mode")
  [[ "$read_only" == "true" ]] && cmd+=(--read-only)
  if [[ "$read_only" != "true" && "$sandbox_mode" == "" && "$full_auto" == "true" ]]; then
    cmd+=(--full-auto)
  fi
  cmd+=(--timeout "$timeout_secs" --idle-timeout "$idle_timeout_secs" -o "$output_file")
  for ref in "${file_refs[@]}"; do
    cmd+=(--file "$ref")
  done
  if [[ -n "$session_id" && "$session_id" != "null" ]]; then
    cmd+=(--session "$session_id")
  fi
  cmd+=("$message")

  update_state_args "$broker_id" \
    --arg run_dir "$run_dir" \
    --arg message "$message" \
    --arg updated_at "$(now_iso)" \
    --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
    '.status = "running"
     | .current_run_dir = $run_dir
     | .current_message = $message
     | .pending_count = $pending
     | .updated_at = $updated_at'
  log_activity "$broker_id" "Starting run $run_id"
  append_event "$broker_id" "run_started" "$(jq -cn --arg run_id "$run_id" --arg message "$message" '{run_id:$run_id, message:$message}')"

  "${cmd[@]}" >"$stdout_file" 2>"$stderr_file" &
  local ask_pid=$!
  update_state_args "$broker_id" \
    --argjson pid "$ask_pid" \
    --arg updated_at "$(now_iso)" \
    '.current_pid = $pid | .updated_at = $updated_at'

  while kill -0 "$ask_pid" 2>/dev/null; do
    update_state_args "$broker_id" \
      --arg progress "$(tail_excerpt "$stderr_file" 10)" \
      --arg updated_at "$(now_iso)" \
      --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
      '.latest_progress = $progress | .updated_at = $updated_at | .pending_count = $pending'
    sleep 1
  done

  local exit_code=0 new_session_id output_path latest_summary
  wait "$ask_pid" 2>/dev/null && exit_code=0 || exit_code=$?
  new_session_id="$(awk -F= '/^session_id=/{print $2}' "$stdout_file" | tail -1)"
  output_path="$(awk -F= '/^output_path=/{print $2}' "$stdout_file" | tail -1)"
  latest_summary="$(head -40 "$output_file" 2>/dev/null || true)"

  if [[ -n "$new_session_id" ]]; then
    update_state_args "$broker_id" --arg session_id "$new_session_id" '.session_id = $session_id'
  fi

  if [[ -n "$output_path" && -f "$output_path" ]]; then
    cp "$output_path" "$(latest_output_for "$broker_id")"
  elif [[ -f "$output_file" ]]; then
    cp "$output_file" "$(latest_output_for "$broker_id")"
  fi

  rm -f "$qfile"

  local next_status last_run_status
  case "$exit_code" in
    0) next_status="waiting_input"; last_run_status="completed" ;;
    4) next_status="waiting_input"; last_run_status="waiting_for_input" ;;
    2) next_status="attention_required"; last_run_status="timeout" ;;
    3) next_status="attention_required"; last_run_status="fatal_error" ;;
    *) next_status="attention_required"; last_run_status="error" ;;
  esac

  update_state_args "$broker_id" \
    --arg status "$next_status" \
    --arg last_run_status "$last_run_status" \
    --arg latest_progress "$(tail_excerpt "$stderr_file" 10)" \
    --arg latest_summary "$latest_summary" \
    --arg output_path "${output_path:-$output_file}" \
    --arg updated_at "$(now_iso)" \
    --argjson exit_code "$exit_code" \
    --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
    '.status = $status
     | .last_run_status = $last_run_status
     | .current_pid = null
     | .last_exit_code = $exit_code
     | .last_output_path = $output_path
     | .latest_progress = $latest_progress
     | .latest_summary = $latest_summary
     | .pending_count = $pending
     | .updated_at = $updated_at'
  log_activity "$broker_id" "Run $run_id finished with exit $exit_code ($last_run_status)"
  append_event "$broker_id" "run_finished" "$(jq -cn --arg run_id "$run_id" --arg status "$last_run_status" --arg output_path "${output_path:-$output_file}" --argjson exit_code "$exit_code" '{run_id:$run_id, status:$status, output_path:$output_path, exit_code:$exit_code}')"
  return 0
}

handle_worker() {
  local session_dir="$1"
  local broker_id
  broker_id="$(basename "$session_dir")"
  mkdir -p "$session_root"
  update_state_args "$broker_id" \
    --argjson worker_pid "$$" \
    --arg updated_at "$(now_iso)" \
    '.worker_pid = $worker_pid | .updated_at = $updated_at | if .status == "starting" then .status = "queued" else . end'
  log_activity "$broker_id" "Worker online"

  while true; do
    if [[ -f "$session_dir/stop.requested" ]]; then
      update_state_args "$broker_id" \
        --arg updated_at "$(now_iso)" \
        '.status = "stopped" | .current_pid = null | .updated_at = $updated_at'
      log_activity "$broker_id" "Worker stopping"
      append_event "$broker_id" "worker_stopped" '{}'
      exit 0
    fi

    if worker_run_turn "$session_dir"; then
      :
    else
      update_state_args "$broker_id" \
        --arg updated_at "$(now_iso)" \
        --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
        'if .status == "starting" or .status == "queued" then .status = "waiting_input" else . end
         | .pending_count = $pending
         | .updated_at = $updated_at'
      sleep 1
    fi
  done
}

handle_send() {
  local interrupt=false
  local broker_id="${1:-}"
  shift || true
  local message=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interrupt) interrupt=true; shift ;;
      *) if [[ -z "$message" ]]; then message="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; exit 1; fi ;;
    esac
  done
  [[ -n "$broker_id" ]] || { echo "[ERROR] send requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"
  message="$(trim_whitespace "$message")"
  [[ -n "$message" ]] || { echo "[ERROR] send requires a message." >&2; exit 1; }

  enqueue_message "$broker_id" "$message" "$interrupt"
  local current_pid
  current_pid="$(resolve_state_value "$broker_id" '.current_pid // empty')"
  if [[ "$interrupt" == "true" && -n "$current_pid" && "$current_pid" != "null" ]] && kill -0 "$current_pid" 2>/dev/null; then
    kill -TERM "$current_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$current_pid" 2>/dev/null || true
    log_activity "$broker_id" "Interrupt requested for current run"
    append_event "$broker_id" "interrupt_requested" '{}'
  fi

  update_state_args "$broker_id" \
    --arg updated_at "$(now_iso)" \
    --argjson pending "$(queue_count "$(queue_dir_for "$broker_id")")" \
    'if .current_pid == null then .status = "queued" else . end
     | .pending_count = $pending
     | .updated_at = $updated_at'
  printf 'broker_id=%s\n' "$broker_id"
  printf 'queued=%s\n' "true"
  printf 'pending_count=%s\n' "$(queue_count "$(queue_dir_for "$broker_id")")"
}

handle_status() {
  local broker_id="${1:-}"
  local json_output=false
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_output=true; shift ;;
      *) echo "[ERROR] Unexpected argument for status: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$broker_id" ]] || { echo "[ERROR] status requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"

  local state_file current_run_dir recent_progress latest_output_path
  state_file="$(state_file_for "$broker_id")"
  current_run_dir="$(jq -r '.current_run_dir // empty' "$state_file")"
  latest_output_path="$(jq -r '.last_output_path // empty' "$state_file")"
  recent_progress=""
  if [[ -n "$current_run_dir" && -f "$current_run_dir/stderr.txt" ]]; then
    recent_progress="$(tail_excerpt "$current_run_dir/stderr.txt" 10)"
  fi
  if [[ -z "$recent_progress" ]]; then
    recent_progress="$(jq -r '.latest_progress // ""' "$state_file")"
  fi

  if [[ "$json_output" == "true" ]]; then
    jq \
      --arg recent_progress "$recent_progress" \
      --arg latest_output_excerpt "$(head -20 "$(latest_output_for "$broker_id")" 2>/dev/null || true)" \
      '. + {recent_progress:$recent_progress, latest_output_excerpt:$latest_output_excerpt}' \
      "$state_file"
    return
  fi

  printf 'broker_id=%s\n' "$broker_id"
  jq -r '"status=" + .status,
         "session_id=" + (.session_id // ""),
         "pending_count=" + (.pending_count|tostring),
         "last_run_status=" + .last_run_status,
         "last_exit_code=" + ((.last_exit_code // "")|tostring),
         "current_run_dir=" + (.current_run_dir // ""),
         "last_output_path=" + (.last_output_path // ""),
         "updated_at=" + .updated_at' "$state_file"
  if [[ -n "$recent_progress" ]]; then
    echo "--- recent_progress ---"
    printf '%s\n' "$recent_progress"
  fi
}

handle_summary() {
  local broker_id="${1:-}"
  [[ -n "$broker_id" ]] || { echo "[ERROR] summary requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"
  jq -r '
    "broker_id=" + .broker_id,
    "status=" + .status,
    "session_id=" + (.session_id // ""),
    "last_run_status=" + .last_run_status,
    "",
    (.latest_summary // "")
  ' "$(state_file_for "$broker_id")"
}

handle_wait() {
  local broker_id="${1:-}"
  shift || true
  local timeout_secs=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout_secs="${2:-0}"; shift 2 ;;
      *) echo "[ERROR] Unexpected argument for wait: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$broker_id" ]] || { echo "[ERROR] wait requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"

  local start now status pending_count
  start="$(date +%s)"
  while true; do
    status="$(resolve_state_value "$broker_id" '.status')"
    pending_count="$(resolve_state_value "$broker_id" '.pending_count // 0')"
    if [[ "$status" != "running" && "$status" != "queued" && "$pending_count" == "0" ]]; then
      handle_status "$broker_id"
      return 0
    fi
    if [[ "$timeout_secs" -gt 0 ]]; then
      now="$(date +%s)"
      if (( now - start >= timeout_secs )); then
        echo "[ERROR] wait timed out." >&2
        return 1
      fi
    fi
    sleep 1
  done
}

handle_logs() {
  local broker_id="${1:-}"
  shift || true
  local follow=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow) follow=true; shift ;;
      *) echo "[ERROR] Unexpected argument for logs: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$broker_id" ]] || { echo "[ERROR] logs requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"
  local path
  path="$(activity_log_for "$broker_id")"
  if [[ "$follow" == "true" ]]; then
    tail -n 50 -f "$path"
  else
    tail -n 50 "$path"
  fi
}

handle_stop() {
  local broker_id="${1:-}"
  [[ -n "$broker_id" ]] || { echo "[ERROR] stop requires a broker id." >&2; exit 1; }
  ensure_session_exists "$broker_id"
  local current_pid worker_pid session_dir
  session_dir="$(session_dir_for "$broker_id")"
  touch "$session_dir/stop.requested"
  current_pid="$(resolve_state_value "$broker_id" '.current_pid // empty')"
  worker_pid="$(resolve_state_value "$broker_id" '.worker_pid // empty')"
  if [[ -n "$current_pid" && "$current_pid" != "null" ]] && kill -0 "$current_pid" 2>/dev/null; then
    kill -TERM "$current_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$current_pid" 2>/dev/null || true
  fi
  if [[ -n "$worker_pid" && "$worker_pid" != "null" ]] && kill -0 "$worker_pid" 2>/dev/null; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$worker_pid" 2>/dev/null || true
  fi
  update_state_args "$broker_id" \
    --arg updated_at "$(now_iso)" \
    '.status = "stopped" | .current_pid = null | .updated_at = $updated_at'
  log_activity "$broker_id" "Stop requested"
  printf 'broker_id=%s\n' "$broker_id"
  printf 'status=stopped\n'
}

main() {
  require_cmd jq
  [[ -f "$ask_script" ]] || { echo "[ERROR] Missing ask_codex.sh: $ask_script" >&2; exit 1; }
  mkdir -p "$session_root"

  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    start) handle_start "$@" ;;
    send) handle_send "$@" ;;
    status) handle_status "$@" ;;
    summary) handle_summary "$@" ;;
    wait) handle_wait "$@" ;;
    logs) handle_logs "$@" ;;
    stop) handle_stop "$@" ;;
    __worker) handle_worker "$@" ;;
    -h|--help|help) usage ;;
    *) echo "[ERROR] Unknown command: $cmd" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
