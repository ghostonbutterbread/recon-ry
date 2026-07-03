#!/usr/bin/env bash

# Output management module

HISTORY_BASELINE_DIR=""

get_history_output_files() {
    if [[ -n "${GENERAL_CONFIG_JSON:-}" ]]; then
        echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
outputs = set()
for tool in data.get('tools', {}).values():
    outs = tool.get('outputs', []) or []
    if isinstance(outs, str):
        outs = [outs]
    for o in outs:
        if o and o not in ('wild.txt', 'urls.txt'):
            outputs.add(o)
print(' '.join(sorted(outputs)))
"
    else
        # Fallback if config isn't loaded for some reason
        echo "alive.txt params.txt params_raw.txt jsfiles.txt secrets.txt dirs.txt dorks.txt"
    fi
}

get_dirs_status_files() {
    local project_dir="$1"
    if [[ -d "$project_dir/dirs_status" ]]; then
        find "$project_dir/dirs_status" -maxdepth 1 -type f -name '*.txt' -printf 'dirs_status/%f\n' | sort
    fi
}

# Initialize baseline for history deltas (snapshot of current project outputs)
init_history_baseline() {
    local project_dir="$1"
    local history_dir="$2"

    HISTORY_BASELINE_DIR="$history_dir/.baseline"
    rm -rf "$HISTORY_BASELINE_DIR"
    mkdir -p "$HISTORY_BASELINE_DIR"

    log_debug "Initializing history baseline: $HISTORY_BASELINE_DIR"

    local files
    files=$(get_history_output_files)
    for file in $files; do
        local base="$HISTORY_BASELINE_DIR/$file"
        mkdir -p "$(dirname "$base")"
        if [[ -f "$project_dir/$file" && -s "$project_dir/$file" ]]; then
            cp "$project_dir/$file" "$base"
        else
            # Ensure baseline exists as empty file for consistent diffing
            : > "$base"
        fi
    done

    local status_files
    status_files=$(get_dirs_status_files "$project_dir")
    for file in $status_files; do
        local src="$project_dir/$file"
        local base="$HISTORY_BASELINE_DIR/$file"
        mkdir -p "$(dirname "$base")"
        if [[ -f "$src" && -s "$src" ]]; then
            cp "$src" "$base"
        else
            : > "$base"
        fi
    done
}

# Copy only new outputs (relative to baseline) to history directory
copy_outputs_to_history() {
    local project_dir="$1"
    local history_dir="$2"

    log_debug "Copying new outputs to history: $history_dir"

    local files
    files=$(get_history_output_files)
    for file in $files; do
        local src="$project_dir/$file"
        local dest="$history_dir/$file"
        local base="$HISTORY_BASELINE_DIR/$file"
        local tmp="$dest.tmp"

        if [[ -f "$src" && -s "$src" ]]; then
            mkdir -p "$(dirname "$dest")"
            # If baseline is missing, fallback to full copy
            if [[ ! -f "$base" ]]; then
                merge_with_anew "$src" "$dest"
                log_debug "Copied $file to history (no baseline)"
                continue
            fi

            awk '
                NR==FNR {
                    if ($0 != "") seen[$0]=1
                    next
                }
                {
                    if ($0 != "" && !seen[$0] && !added[$0]++) print $0
                }
            ' "$base" "$src" > "$tmp"

            if [[ -s "$tmp" ]]; then
                merge_with_anew "$tmp" "$dest"
                rm -f "$tmp"
                log_debug "Appended new entries for $file to history"
            else
                rm -f "$tmp"
                log_debug "No new entries for $file"
            fi
        fi
    done

    local status_files
    status_files=$(get_dirs_status_files "$project_dir")
    for file in $status_files; do
        local src="$project_dir/$file"
        local dest="$history_dir/$file"
        local base="$HISTORY_BASELINE_DIR/$file"
        local tmp="$dest.tmp"

        if [[ -f "$src" && -s "$src" ]]; then
            if [[ ! -f "$base" ]]; then
                mkdir -p "$(dirname "$dest")"
                merge_with_anew "$src" "$dest"
                log_debug "Copied $file to history (no baseline)"
                continue
            fi

            mkdir -p "$(dirname "$dest")"
            awk '
                NR==FNR {
                    if ($0 != "") seen[$0]=1
                    next
                }
                {
                    if ($0 != "" && !seen[$0] && !added[$0]++) print $0
                }
            ' "$base" "$src" > "$tmp"

            if [[ -s "$tmp" ]]; then
                merge_with_anew "$tmp" "$dest"
                rm -f "$tmp"
                log_debug "Appended new entries for $file to history"
            else
                rm -f "$tmp"
                log_debug "No new entries for $file"
            fi
        fi
    done
}

# Merge outputs using anew
merge_with_anew() {
    local source_file="$1"
    local target_file="$2"

    if [[ ! -f "$source_file" ]]; then
        log_debug "Source file $source_file does not exist, skipping merge"
        return 0
    fi

    if [[ ! -s "$source_file" ]]; then
        log_debug "Source file $source_file is empty, skipping merge"
        return 0
    fi

    if command -v anew &> /dev/null; then
        local new_count=$(cat "$source_file" | anew "$target_file" -d | wc -l)
        if [[ $new_count -gt 0 ]]; then
            log_verbose "Added $new_count new entries to $target_file"
        fi
    else
        # Fallback without anew
        cat "$source_file" >> "$target_file"
        sort -u "$target_file" -o "$target_file"
        log_debug "Merged $source_file to $target_file (using sort -u)"
    fi
}

# Create global URLs file (merge wild.txt and urls.txt)
create_global_urls() {
    local project_dir="$1"
    local temp_dir="$project_dir/.tmp_run"
    local global_urls="$temp_dir/urls.txt"
    local seed_url="$temp_dir/url_seed.txt"
    local temp_wild="$temp_dir/wild.txt"
    local preserved_urls=""

    log_debug "Creating global URLs file (temp)"
    mkdir -p "$temp_dir"

    # Preserve URLs already discovered during this run before rebuilding aggregate.
    if [[ -f "$global_urls" && -s "$global_urls" ]]; then
        preserved_urls=$(mktemp)
        cp "$global_urls" "$preserved_urls"
    fi

    : > "$global_urls"
    if [[ -f "$seed_url" && -s "$seed_url" ]]; then
        merge_with_anew "$seed_url" "$global_urls"
    fi
    if [[ -f "$project_dir/urls.txt" && -s "$project_dir/urls.txt" ]]; then
        merge_with_anew "$project_dir/urls.txt" "$global_urls"
    fi
    if [[ -f "$project_dir/wild.txt" && -s "$project_dir/wild.txt" ]]; then
        merge_with_anew "$project_dir/wild.txt" "$global_urls"
    fi
    if [[ -f "$temp_wild" && -s "$temp_wild" ]]; then
        merge_with_anew "$temp_wild" "$global_urls"
    fi
    if [[ -n "$preserved_urls" ]]; then
        if [[ -s "$preserved_urls" ]]; then
            merge_with_anew "$preserved_urls" "$global_urls"
        fi
        rm -f "$preserved_urls"
    fi
}

# Initialize project directory
init_project_dir() {
    local project_dir="$1"

    if [[ ! -d "$project_dir" ]]; then
        mkdir -p "$project_dir"
        log_info "Created project directory: $project_dir"
    fi

    # Create empty files if they don't exist
    for file in urls.txt wild.txt alive.txt params.txt; do
        if [[ ! -f "$project_dir/$file" ]]; then
            touch "$project_dir/$file"
            log_debug "Created empty $file"
        fi
    done
}

# Clean empty files
clean_empty_files() {
    local project_dir="$1"

    for file in wild.txt urls.txt alive.txt params.txt secrets.txt dirs.txt params_raw.txt jsfiles.txt ips.txt hosts.jsonl httpx_ip_raw.txt naabu.jsonl ports.txt httpx.jsonl waf_hosts.txt unprotected_hosts.txt review_queue.jsonl; do
        if [[ -f "$project_dir/$file" && ! -s "$project_dir/$file" ]]; then
            rm -f "$project_dir/$file"
            log_debug "Removed empty file: $file"
        fi
    done
}

# Export results in different formats
export_results() {
    local project_dir="$1"
    local format="$2"  # json, csv, html

    case "$format" in
        json)
            export_json "$project_dir"
            ;;
        csv)
            export_csv "$project_dir"
            ;;
        html)
            export_html "$project_dir"
            ;;
        *)
            log_error "Unknown export format: $format"
            return 1
            ;;
    esac
}

# Export to JSON
export_json() {
    local project_dir="$1"
    local output_file="$project_dir/results.json"

    log_info "Exporting results to JSON: $output_file"

    cat > "$output_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "project_dir": "$project_dir",
    "results": {
EOF

    local first=true
    local files
    files="wild.txt urls.txt $(get_history_output_files)"
    for file in $files; do
        if [[ -f "$project_dir/$file" && -s "$project_dir/$file" ]]; then
            if [[ "$first" == "false" ]]; then
                echo "," >> "$output_file"
            fi
            first=false

            echo "        \"$file\": [" >> "$output_file"
            local line_first=true
            while IFS= read -r line; do
                if [[ "$line_first" == "false" ]]; then
                    echo "," >> "$output_file"
                fi
                line_first=false
                echo -n "            \"$(echo "$line" | sed 's/"/\\"/g')\"" >> "$output_file"
            done < "$project_dir/$file"
            echo "" >> "$output_file"
            echo "        ]" >> "$output_file"
        fi
    done

    cat >> "$output_file" << EOF
    }
}
EOF

    log_success "JSON export completed"
}
