#!/usr/bin/env bash

# Config management module

CONFIG_DIR="$SCRIPT_DIR/config"
DEFAULT_CONFIG_DIR="$CONFIG_DIR/defaults"
GENERAL_CONFIG="$CONFIG_DIR/general.yaml"
PROFILES_CONFIG="$CONFIG_DIR/profiles.yaml"
INSTALL_CONFIG="$CONFIG_DIR/install.yaml"
STATE_CONFIG="$CONFIG_DIR/state.yaml"
PAYLOADS_CONFIG="$CONFIG_DIR/payloads.yaml"

# Associative arrays to store config
declare -A STAGES
declare -A TOOLS
declare -A PROFILES
declare -A INSTALL_INFO

# Project-specific rate limits loaded from rate_limit.conf
declare -A PROJECT_RATE_LIMITS
RATE_LIMIT_CONF_LOADED=false
PROJECT_TIMEOUT=""

# Simple YAML parser for our specific format
parse_yaml() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "Config file not found: $file"
        exit 1
    fi

    # Use python for YAML parsing (most systems have python)
    python3 -c "
import yaml
import sys
import json

try:
    with open('$file', 'r') as f:
        data = yaml.safe_load(f)
    print(json.dumps(data))
except Exception as e:
    print(f'Error parsing YAML: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || {
        log_error "Failed to parse YAML. Is PyYAML installed? (pip3 install pyyaml)"
        exit 1
    }
}

# Ensure a config file exists; restore from defaults when possible.
ensure_config_file() {
    local target="$1"
    local default_name="$2"
    local create_fn="${3:-}"

    if [[ -f "$target" ]]; then
        return 0
    fi

    log_warning "Config file not found, creating: $target"

    if [[ -n "$default_name" && -f "$DEFAULT_CONFIG_DIR/$default_name" ]]; then
        cp "$DEFAULT_CONFIG_DIR/$default_name" "$target"
        return 0
    fi

    if [[ -n "$create_fn" ]]; then
        "$create_fn"
        return 0
    fi

    log_error "No default available for $target"
    exit 1
}

# Load general config
load_general_config() {
    log_debug "Loading general config from $GENERAL_CONFIG"

    ensure_config_file "$GENERAL_CONFIG" "general.yaml"

    if ! command -v python3 &> /dev/null; then
        log_error "Python3 is required for YAML parsing"
        exit 1
    fi

    # Check if PyYAML is installed
    if ! python3 -c "import yaml" 2>/dev/null; then
        log_warning "PyYAML not found. Installing..."
        pip3 install pyyaml --quiet || {
            log_error "Failed to install PyYAML"
            exit 1
        }
    fi

    GENERAL_CONFIG_JSON=$(parse_yaml "$GENERAL_CONFIG")
}

# Load profiles config
load_profiles_config() {
    log_debug "Loading profiles config from $PROFILES_CONFIG"
    ensure_config_file "$PROFILES_CONFIG" "profiles.yaml"
    PROFILES_CONFIG_JSON=$(parse_yaml "$PROFILES_CONFIG")
}

# Load payloads config
load_payloads_config() {
    log_debug "Loading payloads config from $PAYLOADS_CONFIG"
    ensure_config_file "$PAYLOADS_CONFIG" "payloads.yaml"
    PAYLOADS_CONFIG_JSON=$(parse_yaml "$PAYLOADS_CONFIG")
}

# Load install config
load_install_config() {
    log_debug "Loading install config from $INSTALL_CONFIG"
    ensure_config_file "$INSTALL_CONFIG" "install.yaml"
    INSTALL_CONFIG_JSON=$(parse_yaml "$INSTALL_CONFIG")
}

# Load state config
load_state_config() {
    log_debug "Loading state config from $STATE_CONFIG"

    # Create state file if it doesn't exist
    if [[ ! -f "$STATE_CONFIG" ]]; then
        ensure_config_file "$STATE_CONFIG" "state.yaml" create_default_state_config
    fi

    STATE_CONFIG_JSON=$(parse_yaml "$STATE_CONFIG")
}

# Create default state config
create_default_state_config() {
    cat > "$STATE_CONFIG" << 'EOF'
# Tool and Stage State Configuration
# This file tracks which tools and stages are enabled/disabled

# Tool enabled/disabled state
tools:
  subfinder: true
  crt_sh: true
  assetfinder: true
  amass: true
  katana: true
  hakrawler: true
  waybackurls: true
  gau: true
  httpx: true
  gau_params: true
  uro: true
  js_files: true
  unclutter_jsfiles: true
  ffuf: true
  nuclei_secrets: true
  trufflehog: true
  secret_finder: true
  dork_scan: true

# Stage enabled/disabled state
stages:
  subdomain_enum: true
  url_discovery: true
  alive_check: true
  param_discovery: true
  dir_enum: true
  secret_scan: true
  dork: true
EOF
}

# Load project-specific rate limits from $PROJECT_DIR/rate_limit.conf
# If the file doesn't exist the global general.yaml values are used instead.
load_rate_limit_conf() {
    RATE_LIMIT_CONF_LOADED=false
    PROJECT_RATE_LIMITS=()
    PROJECT_TIMEOUT=""

    if [[ -z "${PROJECT_DIR:-}" ]]; then
        return 0
    fi

    local conf_file="$PROJECT_DIR/rate_limit.conf"

    if [[ ! -f "$conf_file" ]]; then
        return 0
    fi

    log_debug "Loading project rate limits from $conf_file"

    while IFS='=' read -r key value; do
        # Skip comment lines and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        # Remove all whitespace from key and value (keys are tool names,
        # values are integers — neither should contain meaningful spaces)
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        [[ -z "$key" ]] && continue
        if [[ "$key" == "timeout" ]]; then
            PROJECT_TIMEOUT="$value"
            continue
        fi
        PROJECT_RATE_LIMITS["$key"]="$value"
    done < "$conf_file"

    RATE_LIMIT_CONF_LOADED=true
    log_debug "Loaded project rate limits (${#PROJECT_RATE_LIMITS[@]} entries)"
}

# Load all configs
load_all_configs() {
    load_general_config
    load_profiles_config
    load_install_config
    load_state_config
    load_payloads_config
    load_rate_limit_conf
}

# Get profile stages
get_profile_stages() {
    local profile="$1"
    echo "$PROFILES_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
profile = data.get('profiles', {}).get('$profile', {})
stages = profile.get('stages', [])
print(' '.join(stages))
"
}

# Get stage info
get_stage_info() {
    local stage="$1"
    local field="$2"
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
stage = data.get('stages', {}).get('$stage', {})
value = stage.get('$field', '')
if isinstance(value, list):
    print(' '.join(value))
elif isinstance(value, bool):
    print('true' if value else 'false')
else:
    print(value)
"
}

# Get tool info
get_tool_info() {
    local tool="$1"
    local field="$2"
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
tool = data.get('tools', {}).get('$tool', {})
value = tool.get('$field', '')
if isinstance(value, list):
    print(' '.join(value))
elif isinstance(value, bool):
    print('true' if value else 'false')
else:
    print(value)
"
}

# Get install info
get_install_info() {
    local tool="$1"
    local field="$2"
    echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
tool = data.get('tools', {}).get('$tool', {})
value = tool.get('$field', '')
print(value)
"
}

# Get install-time dependencies for a configured tool.
get_install_dependencies() {
    local tool="$1"
    echo "$INSTALL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
deps = data.get('tools', {}).get('$tool', {}).get('dependencies', [])
print(' '.join(str(dep) for dep in deps))
"
}

# Check whether install.yaml has metadata for a tool/dependency name.
has_install_tool() {
    local tool="$1"
    local method
    method=$(get_install_info "$tool" "install_method")
    [[ -n "$method" ]]
}

# Check if tool is enabled (from state.yaml)
is_tool_enabled() {
    local tool="$1"
    local enabled=$(echo "$STATE_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
tools = data.get('tools', {})
enabled = tools.get('$tool', True)
print('true' if enabled else 'false')
")
    [[ "$enabled" == "true" ]]
}

# Check if stage is enabled (from state.yaml)
is_stage_enabled() {
    local stage="$1"
    local enabled=$(echo "$STATE_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
stages = data.get('stages', {})
enabled = stages.get('$stage', True)
print('true' if enabled else 'false')
")
    [[ "$enabled" == "true" ]]
}

# Get all tools
get_all_tools() {
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
tools = data.get('tools', {}).keys()
print(' '.join(tools))
"
}

# Get all stages
get_all_stages() {
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
stages = data.get('stages', {}).keys()
print(' '.join(stages))
"
}

# Get rate limit for a specific tool.
# Resolution order:
#   1. rate_limit.conf tool entry  (project-specific, if file exists)
#   2. rate_limit.conf 'default'   (project-specific fallback)
#   3. general.yaml rate_limits    (global config, when no rate_limit.conf)
get_rate_limit() {
    local tool="$1"

    if [[ "$RATE_LIMIT_CONF_LOADED" == "true" ]]; then
        # 1. Tool-specific entry in project rate_limit.conf
        local tool_rate="${PROJECT_RATE_LIMITS[$tool]+x}"
        if [[ -n "$tool_rate" && -n "${PROJECT_RATE_LIMITS[$tool]}" ]]; then
            echo "${PROJECT_RATE_LIMITS[$tool]}"
            return
        fi

        # 2. 'default' entry in project rate_limit.conf
        local default_rate="${PROJECT_RATE_LIMITS[default]+x}"
        if [[ -n "$default_rate" && -n "${PROJECT_RATE_LIMITS[default]}" ]]; then
            echo "${PROJECT_RATE_LIMITS[default]}"
            return
        fi

        # 3. Hardcoded fallback (rate_limit.conf existed but had no usable values)
        echo "150"
        return
    fi

    # rate_limit.conf not present — use general.yaml
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
rate_limits = data.get('rate_limits', {})
default_rate = data.get('defaults', {}).get('rate_limit', 150)
rate = rate_limits.get('$tool', default_rate)
print(rate)
"
}

# Get default timeout (seconds) from config
get_default_timeout() {
    if [[ "$RATE_LIMIT_CONF_LOADED" == "true" ]]; then
        if [[ -n "$PROJECT_TIMEOUT" ]]; then
            echo "$PROJECT_TIMEOUT"
            return
        fi
    fi
    echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys
import json
data = json.load(sys.stdin)
print(data.get('defaults', {}).get('timeout', 300))
"
}

# Get active payload command for a tool (if configured)
get_payload_command() {
    local tool="$1"
    if [[ -z "${PAYLOADS_CONFIG_JSON:-}" ]]; then
        echo ""
        return
    fi
    echo "$PAYLOADS_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tool_cfg = data.get('payloads', {}).get('$tool', {})
active = tool_cfg.get('active')
items = tool_cfg.get('items', {})
cmd = ''
if active and active in items:
    cmd = items.get(active, {}).get('command', '') or ''
print(cmd)
"
}

# Get payload names for a tool
get_payload_names() {
    local tool="$1"
    if [[ -z "${PAYLOADS_CONFIG_JSON:-}" ]]; then
        echo ""
        return
    fi
    echo "$PAYLOADS_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('payloads', {}).get('$tool', {}).get('items', {})
print(' '.join(items.keys()))
"
}

# Get active payload name for a tool
get_active_payload_name() {
    local tool="$1"
    if [[ -z "${PAYLOADS_CONFIG_JSON:-}" ]]; then
        echo ""
        return
    fi
    echo "$PAYLOADS_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tool_cfg = data.get('payloads', {}).get('$tool', {})
print(tool_cfg.get('active', '') or '')
"
}

# Check whether a tool is allowed to receive authenticated HTTP headers.
tool_supports_auth() {
    local tool="$1"
    local supported
    supported=$(echo "$GENERAL_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
value = data.get('tools', {}).get('$tool', {}).get('auth_supported', False)
print('true' if value else 'false')
")
    [[ "$supported" == "true" ]]
}


# Update tool enabled status (writes to state.yaml)
update_tool_status() {
    local tool="$1"
    local enabled="$2"

    # Use python to update the state.yaml file
    python3 << EOF
import yaml
import sys

try:
    with open('$STATE_CONFIG', 'r') as f:
        config = yaml.safe_load(f)

    if config is None:
        config = {}
    if 'tools' not in config:
        config['tools'] = {}

    # Convert string "true"/"false" to Python boolean
    config['tools']['$tool'] = True if '$enabled' == 'true' else False

    with open('$STATE_CONFIG', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

except Exception as e:
    print(f"Error updating tool '{tool}': {e}", file=sys.stderr)
    sys.exit(1)
EOF

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to update tool $tool"
        return 1
    fi

    # Reload state config
    load_state_config
}

# Update stage enabled status (writes to state.yaml)
update_stage_status() {
    local stage="$1"
    local enabled="$2"

    python3 << EOF
import yaml
import sys

try:
    with open('$STATE_CONFIG', 'r') as f:
        config = yaml.safe_load(f)

    if config is None:
        config = {}
    if 'stages' not in config:
        config['stages'] = {}

    # Convert string "true"/"false" to Python boolean
    config['stages']['$stage'] = True if '$enabled' == 'true' else False

    with open('$STATE_CONFIG', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

except Exception as e:
    print(f"Error updating stage '{stage}': {e}", file=sys.stderr)
    sys.exit(1)
EOF

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to update stage $stage"
        return 1
    fi

    # Reload state config
    load_state_config
}

# Update stage parallel status
update_stage_parallel() {
    local stage="$1"
    local parallel="$2"

    python3 << EOF
import yaml

with open('$GENERAL_CONFIG', 'r') as f:
    config = yaml.safe_load(f)

if 'stages' in config and '$stage' in config['stages']:
    # Convert string "true"/"false" to Python boolean
    config['stages']['$stage']['parallel'] = True if '$parallel' == 'true' else False

with open('$GENERAL_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
EOF

    # Reload config
    load_general_config
}

# Batch update all stage statuses at once (more efficient)
batch_update_stage_status() {
    # Build a space-separated list of stage:state pairs
    local updates=""
    local all_stages=$(get_all_stages)

    for stage in $all_stages; do
        local state="$1"
        if [[ -z "$state" ]]; then
            log_error "Missing state for stage $stage"
            return 1
        fi
        shift
        updates="$updates $stage:$state"
    done

    python3 << EOF
import yaml
import sys

try:
    with open('$STATE_CONFIG', 'r') as f:
        config = yaml.safe_load(f)

    if config is None:
        config = {}
    if 'stages' not in config:
        config['stages'] = {}

    # Parse and update all stages
    updates = '$updates'.strip().split()

    for update in updates:
        if ':' in update:
            stage, state = update.split(':', 1)
            config['stages'][stage] = True if state == 'true' else False

    with open('$STATE_CONFIG', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

except Exception as e:
    print(f'Error updating stages: {e}', file=sys.stderr)
    sys.exit(1)
EOF

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to update stages"
        return 1
    fi

    # Reload state config
    load_state_config
}
