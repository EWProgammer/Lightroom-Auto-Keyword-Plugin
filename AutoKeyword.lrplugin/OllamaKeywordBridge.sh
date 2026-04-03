#!/bin/zsh
set -euo pipefail

IMAGE_PATH="${1:-}"
HISTORY_FILE="${2:-}"
OUTPUT_FILE="${3:-}"
MAX_SUGGESTIONS="${4:-10}"
SETTINGS_FILE="${5:-}"

MODEL="${OLLAMA_MODEL:-llava:latest}"
OLLAMA_BIN="${OLLAMA_BIN:-}"
OLLAMA_HOST_VALUE="${OLLAMA_HOST:-http://127.0.0.1:11434}"
CPU_ONLY=""
EXISTING_KEYWORDS=""
NUM_CTX="2048"
KEEP_ALIVE="10m"
PID_FILE="/tmp/lrkw_ollama_started_by_plugin.pid"

if [[ "$OLLAMA_HOST_VALUE" != http://* && "$OLLAMA_HOST_VALUE" != https://* ]]; then
  OLLAMA_HOST_VALUE="http://${OLLAMA_HOST_VALUE}"
fi
OLLAMA_HOST_VALUE="${OLLAMA_HOST_VALUE%/}"

if [[ -z "$IMAGE_PATH" || -z "$OUTPUT_FILE" ]]; then
  echo "" > "${OUTPUT_FILE:-/tmp/lrkw_empty.txt}"
  echo "ERROR: Missing required arguments (IMAGE_PATH and OUTPUT_FILE)" >&2
  exit 1
fi

install_ollama() {
  curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
}

record_started_pid() {
  local pid="$1"
  local started_at=""

  [[ -n "$pid" ]] || return 0
  started_at="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//')"
  printf '%s|%s\n' "$pid" "$started_at" > "$PID_FILE"
}

find_running_ollama_pid() {
  pgrep -f "ollama serve" 2>/dev/null | head -n 1
}

find_lightroom_pid() {
  local current="$$"
  local name=""
  local parent=""

  for _ in {1..12}; do
    [[ -n "$current" && "$current" != "0" ]] || break
    name="$(ps -p "$current" -o comm= 2>/dev/null | sed 's/^ *//')"
    case "$name" in
      *Lightroom*|*lightroom*)
        printf '%s\n' "$current"
        return 0
        ;;
    esac

    parent="$(ps -p "$current" -o ppid= 2>/dev/null | tr -d '[:space:]')"
    current="$parent"
  done

  return 1
}

launch_watchdog() {
  local lightroom_pid="$1"
  local ollama_pid="$2"
  local expected_start="$3"

  [[ -n "$lightroom_pid" && -n "$ollama_pid" ]] || return 0

  nohup /bin/sh -c '
    LR_PID="$1"
    OLLAMA_PID="$2"
    EXPECTED_START="$3"
    PID_FILE="$4"
    i=0
    while [ "$i" -lt 1800 ]; do
      kill -0 "$LR_PID" >/dev/null 2>&1 || break
      sleep 2
      i=$((i + 1))
    done

    if kill -0 "$OLLAMA_PID" >/dev/null 2>&1; then
      CURRENT_COMMAND="$(ps -p "$OLLAMA_PID" -o command= 2>/dev/null)"
      CURRENT_START="$(ps -p "$OLLAMA_PID" -o lstart= 2>/dev/null | sed '"'"'s/^ *//'"'"')"
      case "$CURRENT_COMMAND" in
        *"ollama serve"*)
          if [ -z "$EXPECTED_START" ] || [ "$CURRENT_START" = "$EXPECTED_START" ]; then
            kill "$OLLAMA_PID" >/dev/null 2>&1 || true
            sleep 1
            kill -0 "$OLLAMA_PID" >/dev/null 2>&1 && kill -9 "$OLLAMA_PID" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    fi

    rm -f "$PID_FILE"
  ' sh "$lightroom_pid" "$ollama_pid" "$expected_start" "$PID_FILE" >/dev/null 2>&1 &
}

adopt_running_ollama_for_session() {
  local ollama_pid=""
  local started_at=""
  local lightroom_pid=""

  ollama_pid="$(find_running_ollama_pid || true)"
  [[ -n "$ollama_pid" ]] || return 0

  started_at="$(ps -p "$ollama_pid" -o lstart= 2>/dev/null | sed 's/^ *//')"
  printf '%s|%s\n' "$ollama_pid" "$started_at" > "$PID_FILE"
  lightroom_pid="$(find_lightroom_pid || true)"
  launch_watchdog "$lightroom_pid" "$ollama_pid" "$started_at"
}

json_escape() {
  printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
}

load_settings_file() {
  local path="$1"
  [[ -n "$path" && -f "$path" ]] || return 0

  while IFS='=' read -r key value; do
    [[ -n "${key:-}" ]] || continue
    case "$key" in
      MODEL) MODEL="${value:-$MODEL}" ;;
      CPU_ONLY) CPU_ONLY="${value:-}" ;;
      EXISTING_KEYWORDS) EXISTING_KEYWORDS="${value:-}" ;;
      NUM_CTX) NUM_CTX="${value:-$NUM_CTX}" ;;
    esac
  done < "$path"
}

load_settings_file "$SETTINGS_FILE"

if [[ -z "$OLLAMA_BIN" ]]; then
  if command -v ollama >/dev/null 2>&1; then
    OLLAMA_BIN="$(command -v ollama)"
  elif [[ -x "/usr/local/bin/ollama" ]]; then
    OLLAMA_BIN="/usr/local/bin/ollama"
  elif [[ -x "/opt/homebrew/bin/ollama" ]]; then
    OLLAMA_BIN="/opt/homebrew/bin/ollama"
  fi
fi

if [[ -z "$OLLAMA_BIN" ]]; then
  install_ollama || true
  if command -v ollama >/dev/null 2>&1; then
    OLLAMA_BIN="$(command -v ollama)"
  elif [[ -x "/usr/local/bin/ollama" ]]; then
    OLLAMA_BIN="/usr/local/bin/ollama"
  elif [[ -x "/opt/homebrew/bin/ollama" ]]; then
    OLLAMA_BIN="/opt/homebrew/bin/ollama"
  fi
fi

if [[ -z "$OLLAMA_BIN" ]]; then
  echo "" > "$OUTPUT_FILE"
  echo "ERROR: Ollama binary not found. Download from https://ollama.ai" >&2
  exit 1
fi

if curl -fsS "${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
  adopt_running_ollama_for_session
fi

if ! curl -fsS "${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
  if [[ "$CPU_ONLY" == "true" ]]; then
    OLLAMA_LLM_LIBRARY="cpu" nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  else
    nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  fi
  OLLAMA_STARTED_PID="$!"
  record_started_pid "$OLLAMA_STARTED_PID"
  OLLAMA_STARTED_AT="$(ps -p "$OLLAMA_STARTED_PID" -o lstart= 2>/dev/null | sed 's/^ *//')"
  LIGHTROOM_PID="$(find_lightroom_pid || true)"
  launch_watchdog "$LIGHTROOM_PID" "$OLLAMA_STARTED_PID" "$OLLAMA_STARTED_AT"

  for _ in {1..180}; do
    if curl -fsS "${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if ! "$OLLAMA_BIN" show "$MODEL" >/dev/null 2>&1; then
  curl -fsS "${OLLAMA_HOST_VALUE}/api/pull" -d "{\"name\":\"${MODEL}\",\"stream\":false}" >/dev/null 2>&1 || "$OLLAMA_BIN" pull "$MODEL" >/dev/null 2>&1 || true
fi

if ! "$OLLAMA_BIN" show "$MODEL" >/dev/null 2>&1; then
  for candidate in llava:latest llava:7b gemma3:4b; do
    if "$OLLAMA_BIN" show "$candidate" >/dev/null 2>&1; then
      MODEL="$candidate"
      break
    fi
  done
fi

# Verify we have a valid model
if ! "$OLLAMA_BIN" show "$MODEL" >/dev/null 2>&1; then
  echo "" > "$OUTPUT_FILE"
  echo "ERROR: No valid Ollama model found. Tried: $MODEL, llava:latest, llava:7b, gemma3:4b" >&2
  exit 1
fi

HISTORY_TEXT=""
if [[ -n "$HISTORY_FILE" && -f "$HISTORY_FILE" ]]; then
  HISTORY_TEXT="$(cat "$HISTORY_FILE")"
fi

PROMPT="You are a Lightroom keyword assistant. Analyze this photo and return concise Lightroom keywords only. "
PROMPT+="Return about ${MAX_SUGGESTIONS} keywords, comma-separated, no numbering, no explanations. "
PROMPT+="Prefer concrete subjects, scene, action, mood, lighting, and style. "
if [[ -n "$HISTORY_TEXT" ]]; then
  PROMPT+="If relevant, align with this historical keyword style: ${HISTORY_TEXT} "
fi
if [[ -n "$EXISTING_KEYWORDS" ]]; then
  PROMPT+="Do not repeat keywords already attached to this photo: ${EXISTING_KEYWORDS} "
fi
PROMPT+="Return keywords only."

IMAGE_BASE64="$(base64 < "$IMAGE_PATH" | tr -d '\r\n')"
PROMPT_ESCAPED="$(json_escape "$PROMPT")"

REQUEST_BODY="$(cat <<EOF
{"model":"$MODEL","prompt":"$PROMPT_ESCAPED","stream":false,"keep_alive":"$KEEP_ALIVE","images":["$IMAGE_BASE64"],"options":{"num_ctx":$NUM_CTX}}
EOF
)"

RAW_OUTPUT="$(curl -fsS "${OLLAMA_HOST_VALUE}/api/generate" -H 'Content-Type: application/json' -d "$REQUEST_BODY" 2>/dev/null || true)"
RESPONSE_TEXT="$(printf '%s' "$RAW_OUTPUT" | sed -n 's/.*"response":"\([^"]*\)".*/\1/p' | sed 's/\\"/"/g; s/\\n/, /g; s/\\r//g; s/[[:space:]]\+/ /g; s/^,*//; s/,*$//')"

if [[ -z "$RESPONSE_TEXT" ]]; then
  echo "ERROR: Ollama model returned empty response" >&2
  echo "" > "$OUTPUT_FILE"
  exit 1
fi

echo "$RESPONSE_TEXT" > "$OUTPUT_FILE"
exit 0
