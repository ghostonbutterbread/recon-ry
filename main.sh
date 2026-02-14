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

# General usage information
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

For command-specific help, use:
    $(basename "$0") <command> --help

Examples:
    $(basename "$0") recon --help
    $(basename "$0") secrets --help
    $(basename "$0") recon --url example.com --full
    $(basename "$0") enable_tools
EOF
}

# Recon command help
show_recon_help() {
    cat << EOF
Usage: $(basename "$0") recon [options]

Description:
    Run reconnaissance scans based on selected profile. Supports subdomain
    enumeration, URL discovery, alive checks, parameter discovery, directory
    enumeration, and more.

Options:
    --profile <name>    Profile to run (default: full)
    --full              Run full reconnaissance (all stages)
    --subs              Subdomain enumeration only
    --fast              Quick scan (subdomain + alive check)
    --urls              URL discovery and alive check (requires wild.txt)
    --dork              Google dorking only
    --project <dir>     Project directory path (required for saving results)
    --url <url>         Target URL/domain to scan
    -v                  Verbose output (show tool names)
    -vv                 Very verbose (show full tool output)
    --dry-run           Show what would be executed without running
    --update            Update tools before running
    -h, --help          Show this help message

Profiles:
    full                Full reconnaissance scan (all stages)
    subs                Subdomain enumeration only
    fast                Quick scan (subdomain + alive check)
    urls                URL discovery and alive check
    secrets             Secret scanning on existing data
    dork                Google dorking

Examples:
    # Full recon on a domain (saves to project directory)
    $(basename "$0") recon --url example.com --project ~/bounties/example --full -vv

    # Subdomain enumeration only
    $(basename "$0") recon --url example.com --project ~/bounties/example --subs -v

    # Quick scan with verbose output
    $(basename "$0") recon --url example.com --project ~/bounties/example --fast -vv

    # Recon using existing data (no URL needed)
    $(basename "$0") recon --project ~/bounties/example --full

    # Single URL mode (output to stdout, no project directory)
    $(basename "$0") recon --url example.com --subs

    # Dry run to see what would be executed
    $(basename "$0") recon --url example.com --project ~/bounties/example --full --dry-run

Notes:
    - Either --project or --url must be specified
    - Subdomain enumeration requires --url or existing wild.txt
    - Use --project to save results, omit for stdout-only output
    - Results are saved to history directory with timestamp
EOF
}

# Secrets command help
show_secrets_help() {
    cat << EOF
Usage: $(basename "$0") secrets [options]

Description:
    Run secret scanning operations on discovered URLs and JavaScript files.
    Uses Nuclei, TruffleHog, and SecretFinder to detect exposed secrets,
    API keys, credentials, and sensitive data.

Options:
    --profile <name>    Profile to run (default: secrets)
    --secrets           Run secrets profile
    --project <dir>     Project directory path (required)
    --url <url>         Target URL/domain (optional if data exists)
    -v                  Verbose output (show tool names)
    -vv                 Very verbose (show full tool output)
    --dry-run           Show what would be executed without running
    --update            Update tools before running
    -h, --help          Show this help message

Tools Used:
    nuclei_secrets      Scans URLs for exposures and misconfigurations
    trufflehog          Scans project directory for secrets in files
    secret_finder       Scans JavaScript files for hardcoded secrets

Examples:
    # Run secret scan on existing project data
    $(basename "$0") secrets --project ~/bounties/example

    # Run secret scan with new URL
    $(basename "$0") secrets --url example.com --project ~/bounties/example -vv

    # Dry run to see what would be scanned
    $(basename "$0") secrets --project ~/bounties/example --dry-run

Configuration:
    SecretFinder directory can be configured via environment variable:
        export SECRETFINDER_DIR="/custom/path/to/SecretFinder"

    Default: ~/tools/SecretFinder

Notes:
    - Requires jsfiles.txt for SecretFinder (created during param_discovery)
    - Requires urls.txt for Nuclei scanning
    - TruffleHog scans entire project directory
    - All results are saved to secrets.txt
EOF
}

# Enable Tools command help
show_enable_tools_help() {
    cat << EOF
Usage: $(basename "$0") enable_tools

Description:
    Launch an interactive TUI (Text User Interface) to enable or disable
    individual reconnaissance tools. Changes are saved to the configuration.

Interactive Features:
    - View all available tools
    - Toggle tools on/off
    - See tool descriptions
    - Save configuration changes

Examples:
    $(basename "$0") enable_tools

Notes:
    - Use arrow keys to navigate
    - Press Space to toggle tools
    - Press Enter to save and exit
    - Changes affect which tools run during reconnaissance
EOF
}

# Set Stages command help
show_set_stages_help() {
    cat << EOF
Usage: $(basename "$0") set_stages

Description:
    Launch an interactive TUI to configure reconnaissance stages. Enable or
    disable entire stages and configure their execution order.

Stages:
    subdomain_enum      Subdomain enumeration
    url_discovery       URL discovery and crawling
    alive_check         Check alive hosts and services
    param_discovery     Parameter discovery and JS file extraction
    dir_enum            Directory enumeration
    secret_scan         Secret and sensitive data scanning
    dork                Google dorking

Interactive Features:
    - View all stages
    - Toggle stages on/off
    - Configure dependencies
    - Configure parallel vs sequential execution

Examples:
    $(basename "$0") set_stages

Notes:
    - Use arrow keys to navigate
    - Press Space to toggle stages
    - Press Enter to save and exit
    - Stage dependencies are automatically handled
EOF
}

# Update command help
show_update_help() {
    cat << EOF
Usage: $(basename "$0") update

Description:
    Update all installed reconnaissance tools to their latest versions.
    Checks for updates and installs them automatically.

Examples:
    $(basename "$0") update

Tools Updated:
    - Go-based tools (subfinder, httpx, katana, nuclei, etc.)
    - Python tools (uro)
    - Git-based tools (dirsearch, SecretFinder)

Notes:
    - Requires internet connection
    - May take several minutes depending on number of tools
    - Updates are performed using original installation methods
EOF
}

# Check command help
show_check_help() {
    cat << EOF
Usage: $(basename "$0") check

Description:
    Check the installation status of all reconnaissance tools.
    Shows which tools are installed and which are missing.

Examples:
    $(basename "$0") check

Output:
    - ✓ Installed tools (green)
    - ✗ Missing tools (red)
    - Tool versions (if available)
    - Installation commands for missing tools

Notes:
    - Does not require internet connection
    - Use 'update' command to install missing tools
    - Check output before running reconnaissance
EOF
}

# Show command-specific help
show_command_help() {
    local command="$1"
    case "$command" in
        recon)
            show_recon_help
            ;;
        secrets)
            show_secrets_help
            ;;
        enable_tools)
            show_enable_tools_help
            ;;
        set_stages)
            show_set_stages_help
            ;;
        update)
            show_update_help
            ;;
        check)
            show_check_help
            ;;
        *)
            show_usage
            ;;
    esac
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

    # Check if command is valid
    case "$COMMAND" in
        recon|secrets|enable_tools|set_stages|update|check)
            # Valid command, continue parsing
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac

    # Parse command-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_command_help "$COMMAND"
                exit 0
                ;;
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
            --fast)
                PROFILE="fast"
                shift
                ;;
            --urls)
                PROFILE="urls"
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
                # Load configs first for update to work
                source "$SCRIPT_DIR/src/logger.sh"
                logger_init 0
                source "$SCRIPT_DIR/src/config.sh"
                load_all_configs
                run_update
                shift
                ;;
            *)
                echo "Error: Unknown option: $1"
                echo ""
                show_command_help "$COMMAND"
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
        recon)
            # Validate required arguments
            if [[ -z "$PROJECT_DIR" && -z "$URL" ]]; then
                log_error "Either --project or --url must be specified"
                echo ""
                show_recon_help
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
        secrets)
            # Validate required arguments
            if [[ -z "$PROJECT_DIR" && -z "$URL" ]]; then
                log_error "Either --project or --url must be specified"
                echo ""
                show_secrets_help
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
