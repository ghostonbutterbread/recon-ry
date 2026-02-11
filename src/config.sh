#!/usr/bin/env bash

# Config management module

CONFIG_DIR="$SCRIPT_DIR/config"
GENERAL_CONFIG="$CONFIG_DIR/general.yaml"
PROFILES_CONFIG="$CONFIG_DIR/profiles.yaml"
INSTALL_CONFIG="$CONFIG_DIR/install.yaml"

# Associative arrays to store config
declare -A STAGES
declare -A TOOLS
declare -A PROFILES
declare -A INSTALL_INFO

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

# Load general config
load_general_config() {
    log_debug "Loading general config from $GENERAL_CONFIG"

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
    PROFILES_CONFIG_JSON=$(parse_yaml "$PROFILES_CONFIG")
}

# Load install config
load_install_config() {
    log_debug "Loading install config from $INSTALL_CONFIG"
    INSTALL_CONFIG_JSON=$(parse_yaml "$INSTALL_CONFIG")
}

# Load all configs
load_all_configs() {
    load_general_config
    load_profiles_config
    load_install_config
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

# Check if tool is enabled
is_tool_enabled() {
    local tool="$1"
    local enabled=$(get_tool_info "$tool" "enabled")
    [[ "$enabled" == "true" ]]
}

# Check if stage is enabled
is_stage_enabled() {
    local stage="$1"
    local enabled=$(get_stage_info "$stage" "enabled")
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

# Update tool enabled status
update_tool_status() {
    local tool="$1"
    local enabled="$2"

    # Use python to update the YAML file
    python3 << EOF
import yaml

with open('$GENERAL_CONFIG', 'r') as f:
    config = yaml.safe_load(f)

if 'tools' in config and '$tool' in config['tools']:
    config['tools']['$tool']['enabled'] = $enabled

with open('$GENERAL_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
EOF

    # Reload config
    load_general_config
}

# Update stage enabled status
update_stage_status() {
    local stage="$1"
    local enabled="$2"

    python3 << EOF
import yaml

with open('$GENERAL_CONFIG', 'r') as f:
    config = yaml.safe_load(f)

if 'stages' in config and '$stage' in config['stages']:
    config['stages']['$stage']['enabled'] = $enabled

with open('$GENERAL_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
EOF

    # Reload config
    load_general_config
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
    config['stages']['$stage']['parallel'] = $parallel

with open('$GENERAL_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
EOF

    # Reload config
    load_general_config
}
