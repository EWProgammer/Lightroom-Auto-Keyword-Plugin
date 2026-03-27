#!/bin/zsh
set -euo pipefail

IMAGE_PATH="${1:-}"
HISTORY_FILE="${2:-}"
OUTPUT_FILE="${3:-}"
MAX_SUGGESTIONS="${4:-10}"
MODEL="${OLLAMA_MODEL:-llava:7b}"
OLLAMA_BIN="${OLLAMA_BIN:-}"

if [[ -z "$IMAGE_PATH" || -z "$OUTPUT_FILE" ]]; then
  echo "" > "${OUTPUT_FILE:-/tmp/lrkw_empty.txt}"
  exit 0
fi

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
  echo "" > "$OUTPUT_FILE"
  exit 0
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
PROMPT+="Return keywords only.\n"

RAW_OUTPUT="$("$OLLAMA_BIN" run "$MODEL" "$PROMPT" 2>/dev/null || true)"

if [[ -z "$RAW_OUTPUT" ]]; then
  echo "" > "$OUTPUT_FILE"
  exit 0
fi

# Normalize to a single comma-separated line.
SANITIZED="$(echo "$RAW_OUTPUT" | tr '\n' ',' | sed 's/[[:space:]]\+/ /g' | sed 's/^,*//; s/,*$//' )"

echo "$SANITIZED" > "$OUTPUT_FILE"
