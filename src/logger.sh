#!/usr/bin/env bash

# Logger module with verbosity support

LOGGER_VERBOSE=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Initialize logger
logger_init() {
    LOGGER_VERBOSE="${1:-0}"
}

# Log info message
log_info() {
    echo -e "${BLUE}[*]${NC} $*" >&2
}

# Log success message
log_success() {
    echo -e "${GREEN}[+]${NC} $*" >&2
}

# Log warning message
log_warning() {
    echo -e "${YELLOW}[!]${NC} $*" >&2
}

# Log error message
log_error() {
    echo -e "${RED}[-]${NC} $*" >&2
}

# Log verbose message (only shown with -v or -vv)
log_verbose() {
    if [[ $LOGGER_VERBOSE -ge 1 ]]; then
        echo -e "${CYAN}[v]${NC} $*" >&2
    fi
}

# Log debug message (only shown with -vv)
log_debug() {
    if [[ $LOGGER_VERBOSE -ge 2 ]]; then
        echo -e "${MAGENTA}[d]${NC} $*" >&2
    fi
}

# Log tool output (only shown with -vv)
log_tool_output() {
    if [[ $LOGGER_VERBOSE -ge 2 ]]; then
        while IFS= read -r line; do
            echo -e "${MAGENTA}    ${NC}$line" >&2
        done
    fi
}

# Progress indicator
show_progress() {
    local message="$1"
    echo -ne "${BLUE}[*]${NC} ${message}... " >&2
}

# Complete progress
complete_progress() {
    echo -e "${GREEN}Done${NC}" >&2
}

# Fail progress
fail_progress() {
    echo -e "${RED}Failed${NC}" >&2
}
