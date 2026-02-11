#!/usr/bin/env bash

# Stage execution module

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

    log_info "Running stage: $stage"

    # Check if stage is enabled
    if ! is_stage_enabled "$stage"; then
        log_warning "Stage $stage is disabled, skipping"
        return 0
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

        # Get tool inputs
        local required_files=$(get_tool_info "$tool" "required_files")
        local input_file=""
        if [[ -n "$required_files" && "$required_files" != "[]" ]]; then
            input_file="$project_dir/$(echo "$required_files" | awk '{print $1}')"
        fi

        # Build tool parameter string
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

    if [[ -z "$stages" ]]; then
        log_error "Profile $profile not found or has no stages"
        exit 1
    fi

    log_info "Stages to run: $stages"

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
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local history_dir="$project_dir/history/$timestamp"
    mkdir -p "$history_dir"
    log_info "History directory: $history_dir"

    # Execute each stage
    local failed_stages=0
    for stage in $stages; do
        if ! execute_stage "$stage" "$project_dir" "$domain" "$url"; then
            ((failed_stages++))
            log_error "Stage $stage failed"
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
