#!/usr/bin/env bash

# Background scan management

list_bg_scans() {
    local project_dir="$1"
    local bg_dir="$project_dir/.bg_scans"

    if [[ ! -d "$bg_dir" ]]; then
        log_info "No background scans found"
        return 0
    fi

    local found=false
    for pid_file in "$bg_dir"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        found=true
        local name=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            log_info "Running: $name (pid $pid)"
        else
            log_info "Not running: $name"
        fi
    done

    if [[ "$found" == "false" ]]; then
        log_info "No background scans found"
    fi
}

kill_bg_scans() {
    local project_dir="$1"
    local bg_dir="$project_dir/.bg_scans"

    if [[ ! -d "$bg_dir" ]]; then
        log_info "No background scans found"
        return 0
    fi

    local found=false
    for pid_file in "$bg_dir"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        found=true
        local name=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            log_info "Sent SIGTERM to $name (pid $pid)"
        else
            log_info "Not running: $name"
        fi
    done

    if [[ "$found" == "false" ]]; then
        log_info "No background scans found"
    fi
}
