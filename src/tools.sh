#!/usr/bin/env bash

# Tools execution module

# Check if a tool binary exists
check_tool_exists() {
    local tool="$1"

    # Get tool type from general config
    local tool_type=$(get_tool_info "$tool" "type")

    # Handle different tool types
    case "$tool_type" in
        inline)
            # Inline commands (like crt_sh) don't need binary checks
            # They use built-in commands like curl, jq, etc.
            # Just verify the command dependencies exist
            local command=$(get_tool_info "$tool" "command")

            # Check for common dependencies in the command
            if echo "$command" | grep -q "curl"; then
                command -v curl &> /dev/null || return 1
            fi
            if echo "$command" | grep -q "jq"; then
                command -v jq &> /dev/null || return 1
            fi

            # Inline commands are always "available" if dependencies exist
            return 0
            ;;

        script)
            # Check if script file exists at specified path
            local binary_path=$(get_install_info "$tool" "binary_path")
            if [[ -n "$binary_path" ]]; then
                binary_path="${binary_path/#\~/$HOME}"
                # Resolve relative paths against SCRIPT_DIR (bundled scripts)
                if [[ "$binary_path" != /* ]]; then
                    binary_path="$SCRIPT_DIR/$binary_path"
                fi
                [[ -f "$binary_path" ]]
            else
                # Fallback to binary name check
                local binary_name=$(get_install_info "$tool" "binary_name")
                command -v "$binary_name" &> /dev/null
            fi
            ;;

        binary|*)
            # Default: check for binary in PATH
            local binary_name=$(get_install_info "$tool" "binary_name")
            local binary_path=$(get_install_info "$tool" "binary_path")

            if [[ -n "$binary_path" ]]; then
                # Expand tilde
                binary_path="${binary_path/#\~/$HOME}"
                [[ -f "$binary_path" ]]
            else
                command -v "$binary_name" &> /dev/null
            fi
            ;;
    esac
}

# Execute a tool
execute_tool() {
    local tool="$1"
    local input_file="$2"
    local output_file="$3"
    local domain="$4"
    local url="$5"

    # Check if tool is enabled
    if ! is_tool_enabled "$tool"; then
        log_debug "Tool $tool is disabled, skipping"
        return 0
    fi

    # Check if tool exists
    if ! check_tool_exists "$tool"; then
        log_warning "Tool $tool not found, skipping"
        return 1
    fi

    # Get tool command
    local command=$(get_tool_info "$tool" "command")

    # Get rate limit for this tool
    local rate_limit=$(get_rate_limit "$tool")

    # Replace placeholders
    command="${command//\{\{INPUT\}\}/$input_file}"
    command="${command//\{\{OUTPUT\}\}/$output_file}"
    command="${command//\{\{DOMAIN\}\}/$domain}"
    command="${command//\{\{URL\}\}/$url}"
    command="${command//\{\{PROJECT_DIR\}\}/$PROJECT_DIR}"
    command="${command//\{\{RECON_DIR\}\}/$SCRIPT_DIR}"
    command="${command//\{\{SECRETFINDER_DIR\}\}/${SECRETFINDER_DIR:-$SCRIPT_DIR/tools/SecretFinder}}"
    # Per-tool directories and virtualenvs
    local venv_enabled
    venv_enabled=$(get_install_info "$tool" "venv" | tr '[:upper:]' '[:lower:]')
    local venv_path
    venv_path=$(get_install_info "$tool" "venv_path")

    if [[ "$venv_enabled" == "true" && -z "$venv_path" ]]; then
        venv_path="venvs/$tool"
    fi

    if [[ -n "$venv_path" ]]; then
        venv_path="${venv_path/#\~/$HOME}"
        if [[ "$venv_path" != /* ]]; then
            venv_path="$SCRIPT_DIR/$venv_path"
        fi
        if [[ ! -x "$venv_path/bin/python" ]]; then
            log_warning "Venv missing for $tool: $venv_path (run update to create it)"
            return 1
        fi
        command="${command//\{\{VENV_PYTHON\}\}/$venv_path/bin/python}"
    else
        command="${command//\{\{VENV_PYTHON\}\}/python3}"
    fi
    command="${command//\{\{RATE_LIMIT\}\}/$rate_limit}"

    # Apply payload override if configured
    local payload_command
    payload_command=$(get_payload_command "$tool")
    if [[ -n "$payload_command" ]]; then
        command="$payload_command"
        command="${command//\{\{INPUT\}\}/$input_file}"
        command="${command//\{\{OUTPUT\}\}/$output_file}"
        command="${command//\{\{DOMAIN\}\}/$domain}"
        command="${command//\{\{URL\}\}/$url}"
        command="${command//\{\{PROJECT_DIR\}\}/$PROJECT_DIR}"
        command="${command//\{\{RECON_DIR\}\}/$SCRIPT_DIR}"
        command="${command//\{\{SECRETFINDER_DIR\}\}/${SECRETFINDER_DIR:-$SCRIPT_DIR/tools/SecretFinder}}"
        if [[ -n "$venv_path" ]]; then
            command="${command//\{\{VENV_PYTHON\}\}/$venv_path/bin/python}"
        else
            command="${command//\{\{VENV_PYTHON\}\}/python3}"
        fi
        command="${command//\{\{RATE_LIMIT\}\}/$rate_limit}"
    fi

    log_verbose "Running: $tool"
    log_debug "Command: $command"

    # Resolve effective timeout: flag > config default; 0 = disabled
    local effective_timeout
    if [[ -z "${TOOL_TIMEOUT}" ]]; then
        effective_timeout=$(get_default_timeout)
    else
        effective_timeout=$TOOL_TIMEOUT
    fi

    # Execute command, wrapped with timeout when applicable
    if [[ $VERBOSE -ge 2 ]]; then
        if [[ $effective_timeout -gt 0 ]]; then
            timeout "$effective_timeout" bash -c "$command" 2>&1 | tee -a "$output_file.log" | log_tool_output
        else
            eval "$command" 2>&1 | tee -a "$output_file.log" | log_tool_output
        fi
        local exit_code=${PIPESTATUS[0]}
    else
        if [[ $effective_timeout -gt 0 ]]; then
            timeout "$effective_timeout" bash -c "$command" > /dev/null 2>&1
        else
            eval "$command" > /dev/null 2>&1
        fi
        local exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_debug "Tool $tool completed successfully"
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "Tool $tool timed out after ${effective_timeout}s"
        return 0  # Treat timeout as non-fatal; keep whatever output was produced
    else
        log_warning "Tool $tool failed with exit code $exit_code"
        return 1
    fi
}

# Run tool and append output to file using anew
count_new_entries() {
    local existing_file="$1"
    local candidate_file="$2"

    awk '
        NR==FNR {
            if ($0 != "") seen[$0]=1
            next
        }
        {
            if ($0 != "" && !seen[$0] && !counted[$0]) {
                counted[$0]=1
                c++
            }
        }
        END { print c+0 }
    ' "$existing_file" "$candidate_file" 2>/dev/null
}

run_tool_with_anew() {
    local tool="$1"
    local input_file="$2"
    local output_file="$3"
    local domain="$4"
    local url="$5"

    # Create temp file for tool output
    local temp_output=""
    local keep_partial=false
    local merged=false

    if [[ "$tool" == "ffuf" ]]; then
        local project_dir
        project_dir=$(dirname "$output_file")
        local partial_dir="$project_dir/.partials"
        mkdir -p "$partial_dir"
        temp_output="$partial_dir/${tool}.dirs.txt"
        keep_partial=true
    else
        temp_output=$(mktemp)
    fi

    merge_temp_output() {
        if [[ "${merged:-false}" == "true" ]]; then
            return
        fi
        merged=true

        if [[ -s "$temp_output" ]]; then
            local new_count=0

            if [[ -f "$output_file" ]]; then
                new_count=$(count_new_entries "$output_file" "$temp_output")
            else
                new_count=$(awk 'NF { if (!seen[$0]++) c++ } END { print c+0 }' "$temp_output")
            fi

            if command -v anew &> /dev/null; then
                cat "$temp_output" | anew "$output_file" > /dev/null
            else
                cat "$temp_output" >> "$output_file"
                sort -u "$output_file" -o "$output_file"
                log_debug "Tool $tool merged output without anew (sort -u fallback)"
            fi

            if [[ $new_count -gt 0 ]]; then
                log_success "Tool $tool added $new_count new entries to $(basename "$output_file")"
            else
                log_info "Tool $tool added 0 new entries to $(basename "$output_file")"
            fi
        else
            log_debug "Tool $tool produced no output"
            log_info "Tool $tool added 0 new entries to $(basename "$output_file")"
        fi

        if [[ "$keep_partial" == "true" ]]; then
            : > "$temp_output"
        else
            rm -f "$temp_output"
        fi
    }

    # Ensure partial results are merged on exit/interrupt
    trap 'merge_temp_output' EXIT INT TERM

    parse_ffuf_json() {
        local json_file="$1"
        local out_dir="$2"
        python3 - "$json_file" "$out_dir" << 'PY'
import json, os, sys

json_file, out_dir = sys.argv[1], sys.argv[2]
try:
    with open(json_file, "r") as f:
        data = json.load(f)
except Exception:
    data = {}

results = data.get("results", []) or []
urls = []
by_status = {}

for r in results:
    url = r.get("url") or ""
    status = r.get("status", None)
    if url:
        urls.append(url)
        if status is not None:
            by_status.setdefault(str(status), []).append(url)

os.makedirs(out_dir, exist_ok=True)

def write_unique(path, items):
    seen = set()
    out = []
    for u in items:
        if u not in seen:
            seen.add(u)
            out.append(u)
    with open(path, "w") as f:
        if out:
            f.write("\n".join(out) + "\n")

write_unique(os.path.join(out_dir, "urls.txt"), urls)
for code, items in by_status.items():
    write_unique(os.path.join(out_dir, f"{code}.txt"), items)
PY
    }

    # Execute tool
    local exec_ok=true
    if ! execute_tool "$tool" "$input_file" "$temp_output" "$domain" "$url"; then
        exec_ok=false
        log_warning "Tool $tool failed; attempting to merge partial output"
    fi

    # Use anew to append unique results
    if [[ "$tool" == "ffuf" ]]; then
        local project_dir
        project_dir=$(dirname "$output_file")
        local parsed_dir
        parsed_dir=$(mktemp -d)
        parse_ffuf_json "$temp_output" "$parsed_dir"

        if [[ -s "$parsed_dir/urls.txt" ]]; then
            local new_count=0
            if [[ -f "$output_file" ]]; then
                new_count=$(count_new_entries "$output_file" "$parsed_dir/urls.txt")
            else
                new_count=$(awk 'NF { if (!seen[$0]++) c++ } END { print c+0 }' "$parsed_dir/urls.txt")
            fi
            if command -v anew &> /dev/null; then
                cat "$parsed_dir/urls.txt" | anew "$output_file" > /dev/null
            else
                cat "$parsed_dir/urls.txt" >> "$output_file"
                sort -u "$output_file" -o "$output_file"
                log_debug "Tool $tool merged output without anew (sort -u fallback)"
            fi
            if [[ $new_count -gt 0 ]]; then
                log_success "Tool $tool added $new_count new entries to $(basename "$output_file")"
            else
                log_info "Tool $tool added 0 new entries to $(basename "$output_file")"
            fi
        else
            log_debug "Tool $tool produced no output"
            log_info "Tool $tool added 0 new entries to $(basename "$output_file")"
        fi

        local status_dir="$project_dir/dirs_status"
        mkdir -p "$status_dir"
        for status_file in "$parsed_dir"/*.txt; do
            local base
            base=$(basename "$status_file")
            if [[ "$base" == "urls.txt" ]]; then
                continue
            fi
            if [[ -s "$status_file" ]]; then
                local dest="$status_dir/$base"
                local status_new=0
                if [[ -f "$dest" ]]; then
                    status_new=$(count_new_entries "$dest" "$status_file")
                else
                    status_new=$(awk 'NF { if (!seen[$0]++) c++ } END { print c+0 }' "$status_file")
                fi
                if command -v anew &> /dev/null; then
                    cat "$status_file" | anew "$dest" > /dev/null
                else
                    cat "$status_file" >> "$dest"
                    sort -u "$dest" -o "$dest"
                fi
                if [[ $status_new -gt 0 ]]; then
                    log_success "ffuf added $status_new new entries to dirs_status/$base"
                else
                    log_info "ffuf added 0 new entries to dirs_status/$base"
                fi
            fi
        done

        # Remove dirs.txt after status split (keep status files as canonical output)
        rm -f "$output_file"

        rm -rf "$parsed_dir"
        merge_temp_output
    else
        merge_temp_output
    fi
    trap - EXIT INT TERM

    if [[ "$exec_ok" == "true" ]]; then
        return 0
    fi
    return 1
}

# Run tool without anew (direct output)
run_tool_direct() {
    local tool="$1"
    local input_file="$2"
    local output_file="$3"
    local domain="$4"
    local url="$5"

    execute_tool "$tool" "$input_file" "$output_file" "$domain" "$url"
}

# Run multiple tools in parallel
run_tools_parallel() {
    local tools=("$@")
    local pids=()

    for tool in "${tools[@]}"; do
        # Parse tool with its parameters
        # Format: "tool:input:output:domain:url"
        IFS=':' read -r tool_name input_file output_file domain url <<< "$tool"

        run_tool_with_anew "$tool_name" "$input_file" "$output_file" "$domain" "$url" &
        pids+=($!)
    done

    # Wait for all tools to complete
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ((failed++))
        fi
    done

    return $failed
}

# Run tools sequentially
run_tools_sequential() {
    local tools=("$@")
    local failed=0

    for tool in "${tools[@]}"; do
        # Parse tool with its parameters
        IFS=':' read -r tool_name input_file output_file domain url <<< "$tool"

        if ! run_tool_with_anew "$tool_name" "$input_file" "$output_file" "$domain" "$url"; then
            ((failed++))
        fi
    done

    return $failed
}

# Check if required input files exist and are not empty
check_required_files() {
    local tool="$1"
    local project_dir="$2"

    local required_files=$(get_tool_info "$tool" "required_files")

    if [[ -z "$required_files" || "$required_files" == "[]" ]]; then
        return 0
    fi

    for file in $required_files; do
        local full_path="$project_dir/$file"
        if [[ ! -f "$full_path" ]]; then
            log_debug "Required file missing: $full_path"
            return 1
        fi
        if [[ ! -s "$full_path" ]]; then
            log_debug "Required file empty: $full_path"
            return 1
        fi
    done

    return 0
}
