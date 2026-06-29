#!/usr/bin/env bash

# Auth helper functions for recon-ry. Secret values stay in the auth seed file
# and are only expanded for tools that have native HTTP header support.

: "${RECON_RY_AUTH_SEED:=}"

auth_seed_is_enabled() {
    [[ -n "${RECON_RY_AUTH_SEED:-}" && -f "${RECON_RY_AUTH_SEED:-}" ]]
}

auth_args_for_tool() {
    local tool="$1"
    if ! auth_seed_is_enabled; then
        return 0
    fi
    python3 "$SCRIPT_DIR/scripts/auth_args.py" render --seed "$RECON_RY_AUTH_SEED" --tool "$tool"
}

redact_auth_command() {
    local command="$1"
    if ! auth_seed_is_enabled; then
        printf '%s\n' "$command"
        return 0
    fi
    python3 "$SCRIPT_DIR/scripts/auth_args.py" redact --seed "$RECON_RY_AUTH_SEED" --text "$command" 2>/dev/null || printf '<auth-redaction-failed>\n'
}

write_auth_metadata() {
    local project_dir="$1"
    if ! auth_seed_is_enabled; then
        return 0
    fi
    mkdir -p "$project_dir/.auth"
    chmod 700 "$project_dir/.auth" 2>/dev/null || true
    python3 "$SCRIPT_DIR/scripts/auth_args.py" metadata --seed "$RECON_RY_AUTH_SEED" > "$project_dir/.auth/auth_metadata.json"
    chmod 600 "$project_dir/.auth/auth_metadata.json" 2>/dev/null || true
}
