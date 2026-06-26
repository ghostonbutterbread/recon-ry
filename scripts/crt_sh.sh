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

# Ensure the output file exists before we start appending to it
touch "${OUTPUT}"

append_unique() {
    local output_file="$1"
    if command -v anew &>/dev/null; then
        anew "${output_file}"
    else
        # Read all of stdin first, then merge with existing file and deduplicate
        local incoming
        incoming=$(cat)
        { echo "${incoming}"; cat "${output_file}"; } | sort -u > "${output_file}.tmp" \
            && mv "${output_file}.tmp" "${output_file}"
    fi
}

query_crt_sh() {
    local target="$1"

    local results
    results=$(curl -fsSL "https://crt.sh/?q=${target}&output=json" \
        | jq -r '.[].name_value' 2>/dev/null) || {
        echo "[warn] crt.sh query failed for: ${target}" >&2
        return 0
    }

    [[ -z "${results}" ]] && return 0

    # Normalize wildcard entries (*.example.com -> example.com) and extract valid hostnames
    local hosts
    hosts=$(echo "${results}" \
        | sed 's/\*\.//g' \
        | grep -Eo '([A-Za-z0-9-]+\.)+[A-Za-z]{2,}') || true

    [[ -z "${hosts}" ]] && return 0

    echo "${hosts}" | append_unique "${OUTPUT}"
}

# Query for the root domain first
query_crt_sh "${DOMAIN}"

# If urls_file exists and is non-empty, query for each unique hostname in it
if [[ -n "${URLS_FILE}" && -f "${URLS_FILE}" && -s "${URLS_FILE}" ]]; then
    while IFS= read -r host; do
        [[ -z "${host}" ]] && continue
        # Skip if it's just the root domain we already queried
        [[ "${host}" == "${DOMAIN}" ]] && continue
        query_crt_sh "${host}"
    done < <(sed 's|https\?://||; s|/.*||; s|:.*||' "${URLS_FILE}" | sort -u)
fi
