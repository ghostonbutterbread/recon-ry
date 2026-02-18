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
                [[ -f "$binary_path" && -x "$binary_path" ]]
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
    command="${command//\{\{SECRETFINDER_DIR\}\}/${SECRETFINDER_DIR:-$HOME/tools/SecretFinder}}"
    command="${command//\{\{RATE_LIMIT\}\}/$rate_limit}"

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
run_tool_with_anew() {
    local tool="$1"
    local input_file="$2"
    local output_file="$3"
    local domain="$4"
    local url="$5"

    # Create temp file for tool output
    local temp_output=$(mktemp)

    # Execute tool
    if execute_tool "$tool" "$input_file" "$temp_output" "$domain" "$url"; then
        # Use anew to append unique results
        if [[ -s "$temp_output" ]]; then
            if command -v anew &> /dev/null; then
                cat "$temp_output" | anew "$output_file" > /dev/null
                local new_count=$(cat "$temp_output" | anew "$output_file" -d | wc -l)
                if [[ $new_count -gt 0 ]]; then
                    log_success "Tool $tool found $new_count new entries"
                fi
            else
                # Fallback if anew is not installed
                cat "$temp_output" >> "$output_file"
                sort -u "$output_file" -o "$output_file"
                log_success "Tool $tool completed (anew not found, using sort -u)"
            fi
        else
            log_debug "Tool $tool produced no output"
        fi
        rm -f "$temp_output"
        return 0
    else
        rm -f "$temp_output"
        return 1
    fi
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
