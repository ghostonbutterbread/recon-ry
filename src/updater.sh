#!/usr/bin/env bash

# Update and installation module

# Check if a tool is installed
is_tool_installed() {
    local tool="$1"
    check_tool_exists "$tool"
}

# Install a tool
install_tool() {
    local tool="$1"

    local install_method=$(get_install_info "$tool" "install_method")

    # Skip inline commands - they don't need installation
    if [[ "$install_method" == "inline" ]]; then
        log_verbose "Skipping $tool (inline command - no installation needed)"
        return 0
    fi

    log_info "Installing $tool..."

    local install_command=$(get_install_info "$tool" "install_command")

    if [[ -z "$install_command" ]]; then
        log_error "No install command defined for $tool"
        return 1
    fi

    # Expand tilde in install command
    install_command="${install_command/#\~/$HOME}"

    case "$install_method" in
        go)
            if ! command -v go &> /dev/null; then
                log_error "Go is not installed. Please install Go first."
                return 1
            fi
            log_verbose "Running: $install_command"
            eval "$install_command"
            ;;
        pip)
            if ! command -v pip3 &> /dev/null; then
                log_error "pip3 is not installed. Please install Python3 and pip3 first."
                return 1
            fi
            log_verbose "Running: $install_command"
            eval "$install_command"
            ;;
        git)
            if ! command -v git &> /dev/null; then
                log_error "Git is not installed. Please install Git first."
                return 1
            fi
            log_verbose "Running: $install_command"
            eval "$install_command"
            ;;
        apt)
            log_verbose "Running: $install_command"
            eval "$install_command"
            ;;
        *)
            log_error "Unknown install method: $install_method"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_success "$tool installed successfully"
        return 0
    else
        log_error "Failed to install $tool"
        return 1
    fi
}

# Update a tool
update_tool() {
    local tool="$1"

    local install_method=$(get_install_info "$tool" "install_method")

    # Skip inline commands
    if [[ "$install_method" == "inline" ]]; then
        log_verbose "Skipping $tool (inline command)"
        return 0
    fi

    log_info "Updating $tool..."

    case "$install_method" in
        go)
            # For Go tools, reinstalling with @latest updates them
            install_tool "$tool"
            ;;
        pip)
            local binary_name=$(get_install_info "$tool" "binary_name")
            pip3 install --upgrade "$binary_name"
            ;;
        git)
            local binary_path=$(get_install_info "$tool" "binary_path")
            binary_path="${binary_path/#\~/$HOME}"
            # Resolve relative paths against SCRIPT_DIR
            if [[ -n "$binary_path" && "$binary_path" != /* ]]; then
                binary_path="$SCRIPT_DIR/$binary_path"
            fi
            local repo_dir=$(dirname "$binary_path")
            if [[ -d "$repo_dir/.git" ]]; then
                log_verbose "Pulling latest changes for $tool"
                (cd "$repo_dir" && git pull)
            else
                log_warning "$tool not installed via git, reinstalling"
                install_tool "$tool"
            fi
            ;;
        *)
            log_warning "Update not supported for install method: $install_method"
            return 1
            ;;
    esac
}

# Check tool status
check_tool_status() {
    log_info "Checking tool installation status..."
    echo ""

    # Temporarily disable exit on error for this function
    set +e

    local all_tools=$(get_all_tools)
    local installed=0
    local missing=0
    local inline=0

    for tool in $all_tools; do
        local tool_type=$(get_tool_info "$tool" "type" 2>/dev/null)
        [[ -z "$tool_type" ]] && tool_type="binary"

        if [[ "$tool_type" == "inline" ]]; then
            if is_tool_installed "$tool" 2>/dev/null; then
                echo -e "  ${GREEN}[✓]${NC} $tool ${CYAN}(inline)${NC}"
                ((installed++))
                ((inline++))
            else
                echo -e "  ${YELLOW}[!]${NC} $tool ${CYAN}(inline - missing dependencies)${NC}"
                ((missing++))
            fi
        else
            if is_tool_installed "$tool" 2>/dev/null; then
                echo -e "  ${GREEN}[✓]${NC} $tool"
                ((installed++))
            else
                echo -e "  ${RED}[✗]${NC} $tool"
                ((missing++))
            fi
        fi
    done

    # Re-enable exit on error
    set -e

    echo ""
    log_info "Summary: $installed installed ($inline inline), $missing missing"

    if [[ $missing -gt 0 ]]; then
        echo ""
        log_warning "To install missing tools, run: $(basename "$0") update"
    fi
}

# Install all missing tools
install_missing_tools() {
    log_info "Checking for missing tools..."

    local all_tools=$(get_all_tools)
    local missing_tools=()

    # First pass: collect all missing tools
    for tool in $all_tools; do
        if ! is_tool_installed "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    # If no missing tools, return early
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        log_success "All tools are already installed!"
        return 0
    fi

    # Display missing tools
    echo ""
    log_warning "Found ${#missing_tools[@]} missing tool(s):"
    for tool in "${missing_tools[@]}"; do
        echo "  - $tool"
    done
    echo ""

    # Prompt user for confirmation
    read -p "Would you like to install all missing tools? (y/n): " -n 1 -r
    echo ""
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled by user"
        return 0
    fi

    # Second pass: install all missing tools
    log_info "Installing ${#missing_tools[@]} missing tools..."
    echo ""
    local installed=0
    local failed=0

    # Temporarily disable exit on error to continue installing all tools
    set +e

    for tool in "${missing_tools[@]}"; do
        if install_tool "$tool"; then
            ((installed++))
        else
            ((failed++))
        fi
    done

    # Re-enable exit on error
    set -e

    echo ""
    log_info "Installation complete: $installed installed, $failed failed"
}

# Update all installed tools
update_all_tools() {
    log_info "Updating all installed tools..."

    local all_tools=$(get_all_tools)
    local updated=0
    local failed=0

    for tool in $all_tools; do
        if is_tool_installed "$tool"; then
            if update_tool "$tool"; then
                ((updated++))
            else
                ((failed++))
            fi
        fi
    done

    echo ""
    log_info "Update complete: $updated updated, $failed failed"
}

# Check system dependencies
check_dependencies() {
    log_info "Checking system dependencies..."

    local deps=$(echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
deps = data.get('dependencies', [])
for dep in deps:
    print(dep.get('name', ''))
")

    local missing_deps=()

    for dep in $deps; do
        local check_cmd=$(echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
deps = data.get('dependencies', [])
for d in deps:
    if d.get('name') == '$dep':
        print(d.get('check_command', ''))
        break
")
        if eval "$check_cmd" &> /dev/null; then
            echo -e "  ${GREEN}[✓]${NC} $dep"
        else
            echo -e "  ${RED}[✗]${NC} $dep"
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo ""
        log_warning "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install them manually or with sudo privileges"
    fi
}

# Update (or install) wordlist git repositories
update_wordlists() {
    log_info "Updating wordlist repositories..."

    local names
    names=$(echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for name in data.get('wordlists', {}).keys():
    print(name)
")

    if [[ -z "$names" ]]; then
        log_verbose "No wordlist repositories configured"
        return 0
    fi

    for name in $names; do
        local source path full_path
        source=$(echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('wordlists', {}).get('$name', {}).get('source', ''))")
        path=$(echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('wordlists', {}).get('$name', {}).get('path', ''))")
        full_path="$SCRIPT_DIR/$path"

        if [[ -d "$full_path/.git" ]]; then
            log_info "Updating wordlist $name..."
            if (cd "$full_path" && git pull); then
                log_success "Wordlist $name updated"
            else
                log_error "Failed to update wordlist $name"
            fi
        else
            log_info "Installing wordlist $name from $source..."
            mkdir -p "$(dirname "$full_path")"
            if git clone "$source" "$full_path"; then
                log_success "Wordlist $name installed"
            else
                log_error "Failed to install wordlist $name"
            fi
        fi
    done
}

# Main update function
run_update() {
    log_info "Running update module..."
    echo ""

    # Check dependencies first
    check_dependencies
    echo ""

    # Install missing tools
    install_missing_tools
    echo ""

    # Update existing tools
    update_all_tools
    echo ""

    # Update wordlist repositories
    update_wordlists
    echo ""

    log_success "Update complete!"
}
