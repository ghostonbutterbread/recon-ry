#!/usr/bin/env bash

# Init module - project initialization

# Draw a framed paste box and collect multiline input into a project file.
# The user pastes their list (one entry per line) and presses Ctrl+D to save.
_init_paste_box() {
    local project_dir="$1"
    local filename="$2"
    local label="$3"
    local dest="$project_dir/$filename"

    # Ask before overwriting a non-empty existing file
    if [[ -f "$dest" && -s "$dest" ]]; then
        local line_count
        line_count=$(wc -l < "$dest")
        printf "  %b[*]%b %s already has %d entries. Overwrite? [y/N] " \
            "${YELLOW}" "${NC}" "$filename" "$line_count" >&2
        local answer
        read -r answer || true
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            log_info "Keeping existing $filename"
            return 0
        fi
    fi

    echo "" >&2
    # Box matches TUI width (╔ + 62×═ + ╗ = 64 chars wide)
    echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "  ${CYAN}║${NC}  ${YELLOW}${label}${NC}  (${filename})" >&2
    echo -e "  ${CYAN}║${NC}" >&2
    echo -e "  ${CYAN}║${NC}  Paste entries below, one per line." >&2
    echo -e "  ${CYAN}║${NC}  Press ${YELLOW}Ctrl+D${NC} on an empty line when finished." >&2
    echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}" >&2
    echo "" >&2

    # Collect pasted/typed lines until Ctrl+D (EOF)
    local -a lines=()
    local line
    while IFS= read -r line; do
        lines+=("$line")
    done

    # Write non-blank lines to file
    local count=0
    : > "$dest"
    for line in "${lines[@]}"; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        printf '%s\n' "$line" >> "$dest"
        count=$((count + 1))
    done

    echo "" >&2
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}" >&2
    if [[ $count -eq 0 ]]; then
        log_info "No entries pasted — created empty $filename"
    else
        local noun
        noun=$([ "$count" -eq 1 ] && echo "entry" || echo "entries")
        log_success "Saved $count $noun → $dest"
    fi
    echo "" >&2
}

# Generate rate_limit.conf in the project directory from general.yaml values
_init_generate_rate_limit_conf() {
    local project_dir="$1"
    local conf_file="$project_dir/rate_limit.conf"

    if [[ -f "$conf_file" ]]; then
        printf "  %b[*]%b rate_limit.conf already exists. Overwrite? [y/N] " \
            "${YELLOW}" "${NC}" >&2
        local answer
        read -r answer || true
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            log_info "Keeping existing rate_limit.conf"
            return 0
        fi
    fi

    # Pull default rate and per-tool rates from cached general.yaml JSON
    local conf_body
    conf_body=$(echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
default = data.get('defaults', {}).get('rate_limit', 150)
timeout = data.get('defaults', {}).get('timeout', 300)
rl = data.get('rate_limits', {})
lines = []
lines.append('timeout=' + str(timeout))
lines.append('')
lines.append('default=' + str(default))
lines.append('')
for tool, rate in rl.items():
    lines.append(tool + '=' + str(rate))
print('\n'.join(lines))
")

    cat > "$conf_file" << EOF
# rate_limit.conf — project-specific rate limit overrides
# Generated: $(date)
# Project:   $project_dir
#
# This file takes precedence over global rate limits in general.yaml.
#   - If a tool entry is present and non-empty, that value is used.
#   - If a tool entry is missing or blank, the 'default' value below is used.
#   - Delete this file entirely to fall back to general.yaml values.
#
# timeout is seconds per tool (0 = no timeout). Values are requests per second.

$conf_body
EOF

    log_success "Created rate_limit.conf with defaults from general.yaml"
}

# Main init entry point
run_init() {
    local project_dir="$1"

    # Create project directory if it doesn't exist
    if [[ ! -d "$project_dir" ]]; then
        mkdir -p "$project_dir"
        log_info "Created project directory: $project_dir"
    fi

    log_info "Initializing project: $project_dir"

    # Paste box for urls.txt
    _init_paste_box "$project_dir" "urls.txt" "Target URLs"

    # Paste box for wild.txt
    _init_paste_box "$project_dir" "wild.txt" "Wildcard / Subdomain List"

    # Generate rate_limit.conf
    _init_generate_rate_limit_conf "$project_dir"
    echo "" >&2

    log_success "Project initialized: $project_dir"
}
