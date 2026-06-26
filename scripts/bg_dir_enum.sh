#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="${1:-}"
URL="${2:-}"
HISTORY_DIR="${3:-}"
VERBOSE="${4:-0}"

if [[ -z "$PROJECT_DIR" || -z "$HISTORY_DIR" ]]; then
    echo "Usage: $0 <project_dir> <url> <history_dir> [verbose]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/src/logger.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/tools.sh"
source "$SCRIPT_DIR/src/output.sh"
source "$SCRIPT_DIR/src/stages.sh"

logger_init "$VERBOSE"
load_all_configs

domain=""
if [[ -n "$URL" ]]; then
    domain=$(echo "$URL" | sed -e 's|^https\?://||' -e 's|/.*||')
fi

execute_stage "dir_enum" "$PROJECT_DIR" "$domain" "$URL"
copy_outputs_to_history "$PROJECT_DIR" "$HISTORY_DIR"
