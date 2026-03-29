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

if [[ "$OLLAMA_HOST_VALUE" != http://* && "$OLLAMA_HOST_VALUE" != https://* ]]; then
  OLLAMA_HOST_VALUE="http://${OLLAMA_HOST_VALUE}"
fi
OLLAMA_HOST_VALUE="${OLLAMA_HOST_VALUE%/}"

if [[ -z "$IMAGE_PATH" || -z "$OUTPUT_FILE" ]]; then
  echo "" > "${OUTPUT_FILE:-/tmp/lrkw_empty.txt}"
  exit 0
fi

install_ollama() {
  curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
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
  exit 0
fi

if ! curl -fsS "${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
  if [[ "$CPU_ONLY" == "true" ]]; then
    OLLAMA_LLM_LIBRARY="cpu" nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  else
    nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  fi
  for _ in {1..60}; do
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

HISTORY_TEXT=""
if [[ -n "$HISTORY_FILE" && -f "$HISTORY_FILE" ]]; then
  HISTORY_TEXT="$(cat "$HISTORY_FILE")"
fi

PROMPT="${IMAGE_PATH}\n"
PROMPT+="You are a Lightroom keyword assistant. Analyze this photo and return concise Lightroom keywords only.\n"
PROMPT+="Return about ${MAX_SUGGESTIONS} keywords, comma-separated, no numbering, no explanations.\n"
PROMPT+="Prefer concrete subjects, scene, action, mood, and style.\n"
PROMPT+="If relevant, align with this historical keyword style: ${HISTORY_TEXT}\n"
if [[ -n "$EXISTING_KEYWORDS" ]]; then
  PROMPT+="Do not repeat keywords already attached to this photo: ${EXISTING_KEYWORDS}\n"
fi
PROMPT+="Return keywords only.\n"

RAW_OUTPUT="$("$OLLAMA_BIN" run "$MODEL" "$PROMPT" 2>/dev/null || true)"

if [[ -z "$RAW_OUTPUT" ]]; then
  echo "" > "$OUTPUT_FILE"
  exit 0
fi

# Normalize to a single comma-separated line.
SANITIZED="$(echo "$RAW_OUTPUT" | tr '\n' ',' | sed 's/[[:space:]]\+/ /g' | sed 's/^,*//; s/,*$//' )"

echo "$SANITIZED" > "$OUTPUT_FILE"
