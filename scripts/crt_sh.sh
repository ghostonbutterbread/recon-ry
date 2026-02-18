#!/usr/bin/env bash
# crt_sh.sh - Query crt.sh certificate transparency logs for subdomains
# Usage: crt_sh.sh <domain> <output_file> [urls_file]
#
# If urls_file is provided and non-empty, also queries crt.sh for each
# unique hostname extracted from it (recursive enumeration).

set -euo pipefail

DOMAIN="${1:?Usage: crt_sh.sh <domain> <output_file> [urls_file]}"
OUTPUT="${2:?Usage: crt_sh.sh <domain> <output_file> [urls_file]}"
URLS_FILE="${3:-}"

query_crt_sh() {
    local target="$1"
    curl -s "https://crt.sh/?q=${target}&output=json" \
        | jq -r '.[].name_value' \
        | grep -Po '(\w+\.\w+\.\w+)$' \
        | anew "${OUTPUT}"
}

# Query for the root domain first
query_crt_sh "$DOMAIN"

# If urls_file exists and is non-empty, query for each unique hostname in it
if [[ -n "$URLS_FILE" && -f "$URLS_FILE" && -s "$URLS_FILE" ]]; then
    # Extract unique hostnames from full URLs (strips protocol, path, port)
    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        [[ "$host" == "$DOMAIN" ]] && continue
        query_crt_sh "$host"
    done < <(sed 's|https\?://||; s|/.*||; s|:.*||' "$URLS_FILE" | sort -u)
fi
