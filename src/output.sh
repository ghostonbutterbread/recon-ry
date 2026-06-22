#!/usr/bin/env bash

# Output management module

# Copy outputs to history directory
copy_outputs_to_history() {
    local project_dir="$1"
    local history_dir="$2"

    log_debug "Copying outputs to history: $history_dir"

    for file in wild.txt urls.txt alive.txt params.txt secrets.txt dirs.txt dorks.txt params_raw.txt jsfiles.txt ips.txt hosts.jsonl naabu.jsonl ports.txt httpx.jsonl waf_hosts.txt unprotected_hosts.txt review_queue.jsonl; do
        if [[ -f "$project_dir/$file" && -s "$project_dir/$file" ]]; then
            cp "$project_dir/$file" "$history_dir/"
            log_debug "Copied $file to history"
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
    local global_urls="$project_dir/urls.txt"

    log_debug "Creating global URLs file"

    # Merge wild.txt into urls.txt
    if [[ -f "$project_dir/wild.txt" && -s "$project_dir/wild.txt" ]]; then
        merge_with_anew "$project_dir/wild.txt" "$global_urls"
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

    for file in wild.txt urls.txt alive.txt params.txt secrets.txt dirs.txt params_raw.txt jsfiles.txt ips.txt hosts.jsonl naabu.jsonl ports.txt httpx.jsonl waf_hosts.txt unprotected_hosts.txt review_queue.jsonl; do
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
    for file in wild.txt urls.txt alive.txt params.txt secrets.txt dirs.txt jsfiles.txt ips.txt hosts.jsonl naabu.jsonl ports.txt httpx.jsonl waf_hosts.txt unprotected_hosts.txt review_queue.jsonl; do
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
