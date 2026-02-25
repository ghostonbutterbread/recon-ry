#!/usr/bin/env bash

# TUI (Text User Interface) module

# Terminal control codes
CURSOR_HIDE='\033[?25l'
CURSOR_SHOW='\033[?25h'
CLEAR_SCREEN='\033[2J'
MOVE_HOME='\033[H'
CLEAR_LINE='\033[2K'

# TUI state
declare -a TUI_ITEMS=()
declare -a TUI_STATES=()
declare -i TUI_SELECTED=0
declare -i TUI_MODIFIED=0

# Initialize TUI
tui_init() {
    # Hide cursor
    echo -ne "$CURSOR_HIDE"
    # Clear screen
    echo -ne "$CLEAR_SCREEN$MOVE_HOME"
    # Set trap to restore terminal on exit
    trap tui_cleanup EXIT INT TERM
}

# Cleanup TUI
tui_cleanup() {
    echo -ne "$CURSOR_SHOW"
    echo -ne "\033[0m"  # Reset colors
}

# Draw menu
tui_draw_menu() {
    local title="$1"
    local description="$2"
    local show_checks="${3:-true}"

    # Move to home and clear
    echo -ne "$MOVE_HOME"

    # Draw title
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}${title}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$description" ]]; then
        echo -e "${BLUE}${description}${NC}"
        echo ""
    fi

    # Draw items
    for i in "${!TUI_ITEMS[@]}"; do
        local item="${TUI_ITEMS[$i]}"
        local state=""
        if [[ "${#TUI_STATES[@]}" -gt 0 ]]; then
            state="${TUI_STATES[$i]}"
        fi

        # Clear line
        echo -ne "$CLEAR_LINE"

        # Cursor
        if [[ $i -eq $TUI_SELECTED ]]; then
            echo -ne "${GREEN}> ${NC}"
        else
            echo -ne "  "
        fi

        # Checkbox
        if [[ "$show_checks" == "true" ]]; then
            if [[ "$state" == "true" ]]; then
                echo -ne "${GREEN}[✓]${NC} "
            else
                echo -ne "${RED}[ ]${NC} "
            fi
        fi

        # Item name
        echo -e "$item"
    done

    echo ""
    echo -e "${CYAN}Controls:${NC} ↑/↓ Navigate | Space Select/Deselect | Enter Save | Esc Cancel"
}

# Draw list menu (no checkboxes)
tui_draw_list_menu() {
    local title="$1"
    local description="$2"
    local controls="${3:-↑/↓ Navigate | Enter Select | Esc Back}"

    # Move to home and clear
    echo -ne "$MOVE_HOME"

    # Draw title
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}${title}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$description" ]]; then
        if [[ "$description" == *$'\n'* ]]; then
            local first_line="${description%%$'\n'*}"
            local second_line="${description#*$'\n'}"
            echo -e "${BLUE}${first_line}${NC}"
            echo -e "${MAGENTA}${second_line}${NC}"
        else
            echo -e "${BLUE}${description}${NC}"
        fi
        echo ""
    fi

    # Draw items
    for i in "${!TUI_ITEMS[@]}"; do
        local item="${TUI_ITEMS[$i]}"

        echo -ne "$CLEAR_LINE"
        if [[ $i -eq $TUI_SELECTED ]]; then
            echo -ne "${GREEN}> ${NC}"
        else
            echo -ne "  "
        fi
        echo -e "$item"
    done

    echo ""
    echo -e "${CYAN}Controls:${NC} ${controls}"
}

# Read single key
read_key() {
    local key
    IFS= read -rsn1 key

    # Handle escape sequences (arrow keys)
    if [[ $key == $'\x1b' ]]; then
        local seq=""
        local next=""
        # Read the next byte with a slightly longer timeout for tmux
        if IFS= read -rsn1 -t 0.2 next; then
            seq+="$next"
            # Read remaining bytes quickly
            while IFS= read -rsn1 -t 0.02 next; do
                seq+="$next"
            done
        fi
        case "$seq" in
            *"[A"*|*"OA"*) echo "up" ;;
            *"[B"*|*"OB"*) echo "down" ;;
            "") echo "esc" ;;
            *) echo "other" ;;
        esac
    else
        case "$key" in
            ' ') echo "space" ;;
            '') echo "enter" ;;
            'x'|'X') echo "x" ;;
            'q'|'Q') echo "esc" ;;
            *) echo "other" ;;
        esac
    fi
}

# Run TUI menu
tui_run_menu() {
    local title="$1"
    local description="$2"

    tui_init
    TUI_MODIFIED=0

    while true; do
        tui_draw_menu "$title" "$description"

        local key=$(read_key)

        case "$key" in
            up)
                ((TUI_SELECTED--))
                if [[ $TUI_SELECTED -lt 0 ]]; then
                    TUI_SELECTED=$((${#TUI_ITEMS[@]} - 1))
                fi
                ;;
            down)
                ((TUI_SELECTED++))
                if [[ $TUI_SELECTED -ge ${#TUI_ITEMS[@]} ]]; then
                    TUI_SELECTED=0
                fi
                ;;
            space)
                # Toggle state
                if [[ "${TUI_STATES[$TUI_SELECTED]}" == "true" ]]; then
                    TUI_STATES[$TUI_SELECTED]="false"
                else
                    TUI_STATES[$TUI_SELECTED]="true"
                fi
                TUI_MODIFIED=1
                ;;
            enter)
                # Save and exit
                tui_cleanup
                return 0
                ;;
            esc)
                # Cancel without saving
                tui_cleanup
                TUI_MODIFIED=0
                return 1
                ;;
        esac
    done
}

# Run TUI list menu (no checkboxes)
tui_run_list_menu() {
    local title="$1"
    local description="$2"

    tui_init

    while true; do
        tui_draw_menu "$title" "$description" "false"

        local key
        key=$(read_key)

        case "$key" in
            up)
                ((TUI_SELECTED--))
                if [[ $TUI_SELECTED -lt 0 ]]; then
                    TUI_SELECTED=$((${#TUI_ITEMS[@]} - 1))
                fi
                ;;
            down)
                ((TUI_SELECTED++))
                if [[ $TUI_SELECTED -ge ${#TUI_ITEMS[@]} ]]; then
                    TUI_SELECTED=0
                fi
                ;;
            enter)
                tui_cleanup
                return 0
                ;;
            esc)
                tui_cleanup
                return 1
                ;;
        esac
    done
}

# Enable/disable tools TUI
tui_enable_tools() {
    log_info "Opening tool configuration menu..."

    # Load all tools
    local all_tools=$(get_all_tools)

    # Populate TUI arrays
    TUI_ITEMS=()
    TUI_STATES=()
    for tool in $all_tools; do
        TUI_ITEMS+=("$tool")
        if is_tool_enabled "$tool"; then
            TUI_STATES+=("true")
        else
            TUI_STATES+=("false")
        fi
    done

    TUI_SELECTED=0

    # Run menu
    if tui_run_menu "Tool Configuration" "Select which tools to enable/disable"; then
        if [[ $TUI_MODIFIED -eq 1 ]]; then
            log_info "Saving tool configuration..."

            # Save changes
            for i in "${!TUI_ITEMS[@]}"; do
                local tool="${TUI_ITEMS[$i]}"
                local state="${TUI_STATES[$i]}"
                update_tool_status "$tool" "$state"
            done

            log_success "Tool configuration saved!"
        else
            log_info "No changes made"
        fi
    else
        log_info "Tool configuration cancelled"
    fi
}

# Configure stages TUI
tui_set_stages() {
    log_info "Opening stage configuration menu..."

    # Load all stages
    local all_stages=$(get_all_stages)

    # Populate TUI arrays
    TUI_ITEMS=()
    TUI_STATES=()
    for stage in $all_stages; do
        local description=$(get_stage_info "$stage" "description")
        TUI_ITEMS+=("$stage - $description")
        if is_stage_enabled "$stage"; then
            TUI_STATES+=("true")
        else
            TUI_STATES+=("false")
        fi
    done

    TUI_SELECTED=0

    # Run menu
    if tui_run_menu "Stage Configuration" "Select which stages to enable/disable"; then
        if [[ $TUI_MODIFIED -eq 1 ]]; then
            log_info "Saving stage configuration..."

            # Save changes using batch update
            batch_update_stage_status "${TUI_STATES[@]}"

            log_success "Stage configuration saved!"

            # Ask about parallel execution
            echo ""
            log_info "Configure parallel execution for stages? (y/n)"
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                tui_configure_parallel
            fi
        else
            log_info "No changes made"
        fi
    else
        log_info "Stage configuration cancelled"
    fi
}

# Configure parallel execution for stages
tui_configure_parallel() {
    local all_stages=$(get_all_stages)

    # Populate TUI arrays
    TUI_ITEMS=()
    TUI_STATES=()
    for stage in $all_stages; do
        if is_stage_enabled "$stage"; then
            local description=$(get_stage_info "$stage" "description")
            TUI_ITEMS+=("$stage - $description")
            local parallel=$(get_stage_info "$stage" "parallel")
            TUI_STATES+=("$parallel")
        fi
    done

    TUI_SELECTED=0

    # Run menu
    if tui_run_menu "Parallel Execution Configuration" "Select which stages should run tools in parallel"; then
        if [[ $TUI_MODIFIED -eq 1 ]]; then
            log_info "Saving parallel configuration..."

            # Save changes
            local i=0
            for stage in $all_stages; do
                if is_stage_enabled "$stage"; then
                    local state="${TUI_STATES[$i]}"
                    update_stage_parallel "$stage" "$state"
                    ((i++))
                fi
            done

            log_success "Parallel configuration saved!"
        fi
    else
        log_info "Parallel configuration cancelled"
    fi
}

# Interactive profile creator
tui_create_profile() {
    log_info "Creating new profile..."

    echo -n "Enter profile name: "
    read -r profile_name

    if [[ -z "$profile_name" ]]; then
        log_error "Profile name cannot be empty"
        return 1
    fi

    echo -n "Enter profile description: "
    read -r profile_desc

    # Load all stages
    local all_stages=$(get_all_stages)

    # Populate TUI arrays
    TUI_ITEMS=()
    TUI_STATES=()
    for stage in $all_stages; do
        local description=$(get_stage_info "$stage" "description")
        TUI_ITEMS+=("$stage - $description")
        TUI_STATES+=("false")
    done

    TUI_SELECTED=0

    # Run menu
    if tui_run_menu "Profile: $profile_name" "Select stages for this profile"; then
        # Get selected stages
        local selected_stages=()
        local i=0
        for stage in $all_stages; do
            if [[ "${TUI_STATES[$i]}" == "true" ]]; then
                selected_stages+=("$stage")
            fi
            ((i++))
        done

        if [[ ${#selected_stages[@]} -eq 0 ]]; then
            log_error "No stages selected for profile"
            return 1
        fi

        # Save profile
        log_info "Saving profile: $profile_name"

        # Convert array to Python list format
        local stages_list="["
        for stage in "${selected_stages[@]}"; do
            stages_list+="'$stage', "
        done
        stages_list="${stages_list%, }]"

        python3 << EOF
import yaml

with open('$PROFILES_CONFIG', 'r') as f:
    config = yaml.safe_load(f)

if 'profiles' not in config:
    config['profiles'] = {}

config['profiles']['$profile_name'] = {
    'description': '$profile_desc',
    'stages': $stages_list
}

with open('$PROFILES_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
EOF

        log_success "Profile '$profile_name' created successfully!"
        load_profiles_config
    else
        log_info "Profile creation cancelled"
    fi
}
