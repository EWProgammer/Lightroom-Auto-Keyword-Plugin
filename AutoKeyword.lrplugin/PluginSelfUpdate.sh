#!/bin/sh
set -eu

DOWNLOAD_URL="${1:-}"
PLUGIN_PATH="${2:-}"
RESULT_FILE="${3:-}"

write_result() {
  status="$1"
  message="$2"
  backup_path="${3:-}"
  {
    printf 'status=%s\n' "$status"
    printf 'message=%s\n' "$message"
    printf 'backup=%s\n' "$backup_path"
  } > "$RESULT_FILE"
}

if [ -z "$DOWNLOAD_URL" ] || [ -z "$PLUGIN_PATH" ] || [ -z "$RESULT_FILE" ]; then
  write_result "error" "Missing updater parameters."
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lrkw-update.XXXXXX")"
ZIP_PATH="$TEMP_ROOT/update.zip"
EXTRACT_DIR="$TEMP_ROOT/extract"
PLUGIN_DIR_NAME="$(basename "$PLUGIN_PATH")"
PLUGIN_PARENT="$(dirname "$PLUGIN_PATH")"
BACKUP_PATH="$PLUGIN_PARENT/$PLUGIN_DIR_NAME.backup.$(date +%Y%m%d%H%M%S)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$EXTRACT_DIR"

if ! curl -fL "$DOWNLOAD_URL" -o "$ZIP_PATH"; then
  write_result "error" "Could not download the update package."
  exit 1
fi

if command -v ditto >/dev/null 2>&1; then
  ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"
else
  unzip -oq "$ZIP_PATH" -d "$EXTRACT_DIR"
fi

SOURCE_PLUGIN="$(find "$EXTRACT_DIR" -type d -name "$PLUGIN_DIR_NAME" | head -n 1)"
if [ -z "$SOURCE_PLUGIN" ]; then
  write_result "error" "Downloaded update package did not contain $PLUGIN_DIR_NAME."
  exit 1
fi

cp -R "$PLUGIN_PATH" "$BACKUP_PATH"
cp -R "$SOURCE_PLUGIN"/. "$PLUGIN_PATH"/

write_result "ok" "Update installed." "$BACKUP_PATH"
