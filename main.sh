#!/usr/bin/env bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all modules
source "$SCRIPT_DIR/src/logger.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/tools.sh"
source "$SCRIPT_DIR/src/stages.sh"
source "$SCRIPT_DIR/src/output.sh"
source "$SCRIPT_DIR/src/updater.sh"
source "$SCRIPT_DIR/src/tui.sh"

# Global variables
VERBOSE=0
DRY_RUN=false
PROJECT_DIR=""
URL=""
PROFILE="full"
COMMAND=""

# Usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
    recon               Run reconnaissance based on profile
    secrets             Run secret scanning operations
    enable_tools        Interactive TUI to enable/disable tools
    set_stages          Interactive TUI to configure stages
    update              Update all installed tools
    check               Check tool installation status

Options:
    --profile <name>    Profile to run (default: full)
    --full              Shorthand for --profile full
    --subs              Shorthand for --profile subs
    --secrets           Shorthand for --profile secrets
    --dork              Shorthand for --profile dork
    --project <dir>     Project directory path
    --url <url>         Single URL/domain to scan
    -v                  Verbose output (show tool names)
    -vv                 Very verbose (show full tool output)
    --dry-run           Show what would be executed without running
    --update            Update tools before running
    -h, --help          Show this help message

Examples:
    $(basename "$0") recon --full -vv --project \$HOME/bounties/project1
    $(basename "$0") recon --subs -vv --project \$HOME/bounties/project1 --url google.com
    $(basename "$0") secrets --dork --project \$HOME/bounties/project1
    $(basename "$0") recon --url example.com
    $(basename "$0") enable_tools
    $(basename "$0") update
EOF
}

# Parse command line arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi

    # Handle -h and --help before command parsing
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi

    COMMAND="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --full)
                PROFILE="full"
                shift
                ;;
            --subs)
                PROFILE="subs"
                shift
                ;;
            --secrets)
                PROFILE="secrets"
                shift
                ;;
            --dork)
                PROFILE="dork"
                shift
                ;;
            --project)
                PROJECT_DIR="$2"
                shift 2
                ;;
            --url)
                URL="$2"
                shift 2
                ;;
            -v)
                VERBOSE=1
                shift
                ;;
            -vv)
                VERBOSE=2
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --update)
                run_update
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    # Initialize logger with verbosity
    logger_init "$VERBOSE"

    # Load configurations
    load_all_configs

    case "$COMMAND" in
        recon|secrets)
            # Validate required arguments
            if [[ -z "$PROJECT_DIR" && -z "$URL" ]]; then
                log_error "Either --project or --url must be specified"
                show_usage
                exit 1
            fi

            # Single URL mode (no project)
            if [[ -z "$PROJECT_DIR" && -n "$URL" ]]; then
                log_info "Running in single URL mode (output to stdout)"
                run_recon_url_only "$URL" "$PROFILE"
                exit 0
            fi

            # Project mode
            if [[ ! -d "$PROJECT_DIR" ]]; then
                mkdir -p "$PROJECT_DIR"
                log_info "Created project directory: $PROJECT_DIR"
            fi

            run_recon_project "$PROJECT_DIR" "$URL" "$PROFILE"
            ;;
        enable_tools)
            tui_enable_tools
            ;;
        set_stages)
            tui_set_stages
            ;;
        update)
            run_update
            ;;
        check)
            check_tool_status
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}

parse_args "$@"
main
