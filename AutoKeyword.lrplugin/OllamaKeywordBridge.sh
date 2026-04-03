#!/bin/zsh

# =========================
# SINGLE INSTANCE LOCK FIX
# =========================

LOCK_FILE="${TMPDIR:-/tmp}/lrkw_ollama.lock"

# If lock exists, skip starting Ollama
if [[ -f "$LOCK_FILE" ]]; then
  :
else
  # Check if Ollama already running
  if ! pgrep -x "ollama" >/dev/null 2>&1; then
    if [[ "$CPU_ONLY" == "true" ]]; then
      OLLAMA_LLM_LIBRARY="cpu" nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
    else
      nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
    fi

    record_started_pid "$!"

    # Create lock file
    echo "$!" > "$LOCK_FILE"
  fi
fi
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
PID_FILE="${TMPDIR:-/tmp}/lrkw_ollama_started_by_plugin.pid"

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

if ! curl -fsS "${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
  if [[ "$CPU_ONLY" == "true" ]]; then
    OLLAMA_LLM_LIBRARY="cpu" nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  else
    nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  fi
  record_started_pid "$!"

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
