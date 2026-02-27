#!/usr/bin/env bash

# Stage execution module

# Ensure eyewitness stage runs last when present
reorder_stages_eyewitness_last() {
    local stages="$1"
    local reordered=()
    local saw_eyewitness=false
    local stage

    for stage in $stages; do
        if [[ "$stage" == "eyewitness" ]]; then
            saw_eyewitness=true
            continue
        fi
        reordered+=("$stage")
    done

    if [[ "$saw_eyewitness" == "true" ]]; then
        reordered+=("eyewitness")
    fi

    printf '%s\n' "${reordered[*]}"
}

# Check if stage dependencies are met
check_stage_dependencies() {
    local stage="$1"
    local project_dir="$2"

    local depends_on=$(get_stage_info "$stage" "depends_on")

    if [[ -z "$depends_on" || "$depends_on" == "[]" ]]; then
        return 0
    fi

    # Check if dependency stages have been completed
    # (We can check if their output files exist)
    for dep_stage in $depends_on; do
        local dep_tools=$(get_stage_info "$dep_stage" "tools")
        local has_output=false

        for tool in $dep_tools; do
            local outputs=$(get_tool_info "$tool" "outputs")
            for output in $outputs; do
                if [[ -s "$project_dir/$output" ]]; then
                    has_output=true
                    break 2
                fi
            done
        done

        if [[ "$has_output" == "false" ]]; then
            log_debug "Dependency stage $dep_stage not completed"
            return 1
        fi
    done

    return 0
}

# Execute a stage
execute_stage() {
    local stage="$1"
    local project_dir="$2"
    local domain="$3"
    local url="$4"
    local temp_dir="$project_dir/.tmp_run"

    log_info "Running stage: $stage"

    # Check if stage is enabled
    if ! is_stage_enabled "$stage"; then
        log_warning "Stage $stage is disabled, skipping"
        return 0
    fi

    # Special check for subdomain_enum: tools need a domain; infer from wild.txt if URL not provided
    if [[ "$stage" == "subdomain_enum" ]]; then
        if [[ -z "$domain" ]]; then
            if [[ -s "$project_dir/wild.txt" ]]; then
                domain=$(head -n 1 "$project_dir/wild.txt" | sed -e 's|^https\?://||' -e 's|/.*||')
                if [[ -n "$domain" ]]; then
                    log_info "Subdomain enum domain inferred from wild.txt: $domain"
                else
                    log_warning "Stage subdomain_enum skipped: unable to infer domain from wild.txt"
                    return 0
                fi
            else
                log_warning "Stage subdomain_enum skipped: no URL provided and wild.txt not found"
                log_info "Subdomain enumeration requires --url to be specified"
                return 0
            fi
        fi
    fi

    # Check dependencies
    if ! check_stage_dependencies "$stage" "$project_dir"; then
        log_warning "Stage $stage dependencies not met, skipping"
        return 0
    fi

    # Get stage configuration
    local parallel=$(get_stage_info "$stage" "parallel")
    local tools=$(get_stage_info "$stage" "tools")

    if [[ -z "$tools" ]]; then
        log_warning "No tools configured for stage $stage"
        return 0
    fi

    # Prepare tool execution parameters
    local tool_params=()
    local skipped_tools=0

    for tool in $tools; do
        # Check if tool is enabled
        if ! is_tool_enabled "$tool"; then
            log_debug "Tool $tool is disabled, skipping"
            ((skipped_tools++))
            continue
        fi

        # Check if required files exist
        if ! check_required_files "$tool" "$project_dir"; then
            log_debug "Tool $tool missing required files, skipping"
            ((skipped_tools++))
            continue
        fi

        # Get tool outputs
        local outputs=$(get_tool_info "$tool" "outputs")
        local primary_output=$(echo "$outputs" | awk '{print $1}')
        local output_file="$project_dir/$primary_output"
        if [[ "$primary_output" == "wild.txt" || "$primary_output" == "urls.txt" ]]; then
            output_file="$temp_dir/$primary_output"
        fi

        # Get tool inputs
        local required_files=$(get_tool_info "$tool" "required_files")
        local input_file=""
        if [[ -n "$required_files" && "$required_files" != "[]" ]]; then
            local req_file
            req_file="$(echo "$required_files" | awk '{print $1}')"
            if [[ -f "$temp_dir/$req_file" && -s "$temp_dir/$req_file" ]]; then
                input_file="$temp_dir/$req_file"
            else
                input_file="$project_dir/$req_file"
            fi
        fi

        # Build tool parameter string
        if [[ "$tool" == "eyewitness" ]]; then
            mkdir -p "$project_dir/eyewitness"

            if [[ -n "${EYE_INPUT:-}" ]]; then
                if [[ -f "$EYE_INPUT" ]]; then
                    input_file="$EYE_INPUT"
                else
                    input_file="$temp_dir/eyewitness_input.txt"
                    printf '%s\n' "$EYE_INPUT" > "$input_file"
                fi
                output_file="$project_dir/eyewitness/custom_input"
                tool_params+=("$tool:$input_file:$output_file:$domain:$url")
                continue
            fi

            local params_input=""
            local alive_input=""

            if [[ -f "$temp_dir/params.txt" && -s "$temp_dir/params.txt" ]]; then
                params_input="$temp_dir/params.txt"
            elif [[ -f "$project_dir/params.txt" && -s "$project_dir/params.txt" ]]; then
                params_input="$project_dir/params.txt"
            fi

            if [[ -f "$temp_dir/alive.txt" && -s "$temp_dir/alive.txt" ]]; then
                alive_input="$temp_dir/alive.txt"
            elif [[ -f "$project_dir/alive.txt" && -s "$project_dir/alive.txt" ]]; then
                alive_input="$project_dir/alive.txt"
            fi

            if [[ -n "$params_input" ]]; then
                tool_params+=("$tool:$params_input:$project_dir/eyewitness/params:$domain:$url")
            fi

            if [[ -n "$alive_input" ]]; then
                tool_params+=("$tool:$alive_input:$project_dir/eyewitness/alive:$domain:$url")
            fi

            if [[ -z "$params_input" && -z "$alive_input" ]]; then
                log_debug "Tool $tool missing alive.txt and params.txt, skipping"
                ((skipped_tools++))
            fi
            continue
        fi

        tool_params+=("$tool:$input_file:$output_file:$domain:$url")
    done

    # Check if any tools are runnable
    if [[ ${#tool_params[@]} -eq 0 ]]; then
        log_warning "No runnable tools for stage $stage (all skipped: $skipped_tools)"
        return 0
    fi

    # Execute tools
    if [[ "$parallel" == "true" ]]; then
        log_verbose "Running ${#tool_params[@]} tools in parallel"
        run_tools_parallel "${tool_params[@]}"
    else
        log_verbose "Running ${#tool_params[@]} tools sequentially"
        run_tools_sequential "${tool_params[@]}"
    fi

    local exit_code=$?

    if [[ $exit_code -gt 0 ]]; then
        log_warning "Stage $stage completed with $exit_code failed tools"
    else
        log_success "Stage $stage completed successfully"
    fi

    return $exit_code
}

# Run reconnaissance for project
run_recon_project() {
    local project_dir="$1"
    local url="$2"
    local profile="$3"

    log_info "Starting recon with profile: $profile"
    log_info "Project directory: $project_dir"

    # Check if project directory has existing data
    local has_urls=false
    local has_wild=false

    if [[ -s "$project_dir/urls.txt" ]]; then
        has_urls=true
        log_info "Found existing urls.txt"
    fi

    if [[ -s "$project_dir/wild.txt" ]]; then
        has_wild=true
        log_info "Found existing wild.txt"
    fi

    # If no existing data and no URL provided, exit
    if [[ "$has_urls" == "false" && "$has_wild" == "false" && -z "$url" ]]; then
        log_error "No existing data found and no URL provided"
        log_error "Please provide --url or ensure urls.txt/wild.txt exists in project directory"
        exit 1
    fi

    # Determine domain from URL
    local domain=""
    if [[ -n "$url" ]]; then
        # Extract domain from URL
        domain=$(echo "$url" | sed -e 's|^https\?://||' -e 's|/.*||')
        log_info "Target: $domain"
    fi

    # Get stages for profile
    local stages=$(get_profile_stages "$profile")
    stages=$(reorder_stages_eyewitness_last "$stages")

    if [[ -z "$stages" ]]; then
        log_error "Profile $profile not found or has no stages"
        exit 1
    fi

    log_info "Stages to run: $stages"

    local temp_dir="$project_dir/.tmp_run"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    if [[ -n "$url" ]]; then
        printf '%s\n' "$url" > "$temp_dir/url_seed.txt"
    fi

    if [[ "$DIR_ONLY" == "true" ]]; then
        log_info "Directory fuzzing only (--dir)"
        execute_stage "dir_enum" "$project_dir" "$domain" "$url"
        copy_outputs_to_history "$project_dir" "$history_dir"
        return $?
    fi

    local dir_enum_in_profile=false
    for stage in $stages; do
        if [[ "$stage" == "dir_enum" ]]; then
            dir_enum_in_profile=true
            break
        fi
    done

    # Dry run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN MODE - No tools will be executed"
        for stage in $stages; do
            log_info "Would run stage: $stage"
            local stage_tools=$(get_stage_info "$stage" "tools")
            for tool in $stage_tools; do
                if is_tool_enabled "$tool"; then
                    log_verbose "  - $tool (enabled)"
                else
                    log_debug "  - $tool (disabled)"
                fi
            done
        done
        return 0
    fi

    # Create history directory
    local date_stamp=$(date +"%-m-%-d-%Y")
    local history_dir="$project_dir/history/$date_stamp"
    mkdir -p "$history_dir"
    log_info "History directory: $history_dir"
    init_history_baseline "$project_dir" "$history_dir"

    # Execute each stage
    local failed_stages=0
    for stage in $stages; do
        if [[ "$stage" == "alive_check" ]]; then
            # Ensure wild.txt is merged into urls.txt before httpx
            create_global_urls "$project_dir"
        fi
        if [[ "$stage" == "dir_enum" ]]; then
            # Run directory fuzzing in background after alive_check
            continue
        fi
        if ! execute_stage "$stage" "$project_dir" "$domain" "$url"; then
            ((failed_stages++))
            log_error "Stage $stage failed"
        fi

        if [[ "$stage" == "alive_check" && "$dir_enum_in_profile" == "true" ]]; then
            if is_stage_enabled "dir_enum"; then
                log_info "Starting directory enumeration in background"
                local bg_dir="$project_dir/.bg_scans"
                mkdir -p "$bg_dir"
                local log_file="$history_dir/dir_enum.log"
                bash "$SCRIPT_DIR/scripts/bg_dir_enum.sh" "$project_dir" "$url" "$history_dir" "$VERBOSE" > "$log_file" 2>&1 &
                local bg_pid=$!
                if [[ -n "$bg_pid" ]]; then
                    echo "$bg_pid" > "$bg_dir/dir_enum.pid"
                    log_info "Dir enum running (pid $bg_pid), log: $log_file"
                else
                    log_warning "Failed to start background dir_enum, running in foreground"
                    execute_stage "dir_enum" "$project_dir" "$domain" "$url"
                    copy_outputs_to_history "$project_dir" "$history_dir"
                fi
            else
                log_debug "Stage dir_enum is disabled, skipping background run"
            fi
        fi

        # After each stage, copy outputs to history
        copy_outputs_to_history "$project_dir" "$history_dir"
    done

    # Final summary
    echo ""
    log_info "Recon completed!"
    log_info "Project directory: $project_dir"
    log_info "History saved to: $history_dir"

    if [[ $failed_stages -gt 0 ]]; then
        log_warning "$failed_stages stages had failures"
    else
        log_success "All stages completed successfully"
    fi

    # Show summary of results
    show_results_summary "$project_dir"
}

# Run recon for single URL (stdout only)
run_recon_url_only() {
    local url="$1"
    local profile="$2"

    local domain=$(echo "$url" | sed -e 's|^https\?://||' -e 's|/.*||')

    log_info "Running recon on: $domain"
    log_info "Profile: $profile"

    # Create temp directory
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Get stages for profile
    local stages=$(get_profile_stages "$profile")
    stages=$(reorder_stages_eyewitness_last "$stages")

    if [[ -n "$url" ]]; then
        printf '%s\n' "$url" > "$temp_dir/url_seed.txt"
    fi

    # Execute stages
    for stage in $stages; do
        execute_stage "$stage" "$temp_dir" "$domain" "$url"
    done

    # Output results to stdout
    echo ""
    echo "=== Results ==="
    for file in urls.txt wild.txt alive.txt params.txt; do
        if [[ -s "$temp_dir/$file" ]]; then
            echo ""
            echo "=== $file ==="
            cat "$temp_dir/$file"
        fi
    done
}

# Show results summary
show_results_summary() {
    local project_dir="$1"

    echo ""
    log_info "Results Summary:"

    for file in wild.txt urls.txt alive.txt params.txt secrets.txt dirs.txt; do
        if [[ -f "$project_dir/$file" ]]; then
            local count=$(wc -l < "$project_dir/$file" 2>/dev/null || echo 0)
            printf "  %-15s: %d entries\n" "$file" "$count"
        fi
    done
}
