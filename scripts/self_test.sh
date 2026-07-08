#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/src/logger.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/output.sh"
source "$SCRIPT_DIR/src/tools.sh"

logger_init 0
load_general_config
load_payloads_config

project_dir="/tmp/reconry_selftest_${RANDOM}${RANDOM}"
date_dir=""

cleanup() {
    rm -rf "$project_dir"
}
trap cleanup EXIT

mkdir -p "$project_dir"

touch "$project_dir/urls.txt" "$project_dir/wild.txt" "$project_dir/alive.txt" \
      "$project_dir/params_raw.txt" "$project_dir/params.txt" \
      "$project_dir/jsfiles.txt" "$project_dir/dirs.txt" \
      "$project_dir/secrets.txt" "$project_dir/dorks.txt"

# Seed initial root data (existing project state)
cat > "$project_dir/urls.txt" << 'EOF'
https://a.example.com/
https://b.example.com/
EOF

cat > "$project_dir/wild.txt" << 'EOF'
a.example.com
b.example.com
EOF

cat > "$project_dir/alive.txt" << 'EOF'
https://a.example.com/
EOF

cat > "$project_dir/params_raw.txt" << 'EOF'
https://a.example.com/?id=1
EOF

cat > "$project_dir/params.txt" << 'EOF'
https://a.example.com/?id=1
EOF

cat > "$project_dir/jsfiles.txt" << 'EOF'
https://a.example.com/app.js
EOF

cat > "$project_dir/dirs.txt" << 'EOF'
https://a.example.com/admin
EOF

cat > "$project_dir/secrets.txt" << 'EOF'
https://a.example.com/.env
EOF

cat > "$project_dir/dorks.txt" << 'EOF'
site:example.com ext:sql
EOF

# History dir (date-based)
date_dir="$project_dir/history/$(date +"%-m-%-d-%Y")"
mkdir -p "$date_dir"

init_history_baseline "$project_dir" "$date_dir"

simulate_stage_subdomain_enum() {
    printf '%s\n' 'c.example.com' >> "$project_dir/wild.txt"
    printf '%s\n' 'd.example.com' >> "$project_dir/wild.txt"
}

simulate_stage_url_discovery() {
    printf '%s\n' 'https://c.example.com/' >> "$project_dir/urls.txt"
    printf '%s\n' 'https://d.example.com/' >> "$project_dir/urls.txt"
}

simulate_stage_alive_check() {
    create_global_urls "$project_dir"
    printf '%s\n' 'https://c.example.com/' >> "$project_dir/alive.txt"
    printf '%s\n' 'https://d.example.com/' >> "$project_dir/alive.txt"
}

simulate_stage_param_discovery() {
    printf '%s\n' 'https://c.example.com/?q=1' >> "$project_dir/params_raw.txt"
    printf '%s\n' 'https://d.example.com/?p=2' >> "$project_dir/params_raw.txt"
    printf '%s\n' 'https://c.example.com/?q=1' >> "$project_dir/params.txt"
    printf '%s\n' 'https://d.example.com/?p=2' >> "$project_dir/params.txt"
    printf '%s\n' 'https://c.example.com/main.js' >> "$project_dir/jsfiles.txt"
    printf '%s\n' 'https://d.example.com/site.js' >> "$project_dir/jsfiles.txt"
}

simulate_stage_dir_enum() {
    printf '%s\n' 'https://c.example.com/health' >> "$project_dir/dirs.txt"
    printf '%s\n' 'https://d.example.com/status' >> "$project_dir/dirs.txt"
}

simulate_stage_secret_scan() {
    printf '%s\n' 'https://c.example.com/.git/config' >> "$project_dir/secrets.txt"
}

simulate_stage_dork() {
    printf '%s\n' 'site:example.com ext:log' >> "$project_dir/dorks.txt"
}

# Simulate full run 1
simulate_stage_subdomain_enum
simulate_stage_url_discovery
simulate_stage_alive_check
simulate_stage_param_discovery
simulate_stage_dir_enum
simulate_stage_secret_scan
simulate_stage_dork
copy_outputs_to_history "$project_dir" "$date_dir"

# Re-baseline same day, simulate another run
init_history_baseline "$project_dir" "$date_dir"
printf '%s\n' 'e.example.com' >> "$project_dir/wild.txt"
printf '%s\n' 'https://e.example.com/' >> "$project_dir/urls.txt"
create_global_urls "$project_dir"
printf '%s\n' 'https://e.example.com/' >> "$project_dir/alive.txt"
printf '%s\n' 'https://e.example.com/?z=3' >> "$project_dir/params_raw.txt"
printf '%s\n' 'https://e.example.com/?z=3' >> "$project_dir/params.txt"
printf '%s\n' 'https://e.example.com/app.js' >> "$project_dir/jsfiles.txt"
printf '%s\n' 'https://e.example.com/metrics' >> "$project_dir/dirs.txt"
printf '%s\n' 'https://e.example.com/.env' >> "$project_dir/secrets.txt"
printf '%s\n' 'site:example.com ext:bak' >> "$project_dir/dorks.txt"
copy_outputs_to_history "$project_dir" "$date_dir"

fail=0

expect_count() {
    local file="$1"
    local want="$2"
    local got="0"
    if [[ -f "$file" ]]; then
        got=$(wc -l < "$file" | tr -d ' ')
    fi
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $file expected $want lines, got $got"
        fail=1
    else
        echo "PASS: $file has $want lines"
    fi
}

# Expect only new entries from run 1 and run 2.
expect_count "$date_dir/alive.txt" 3
expect_count "$date_dir/params_raw.txt" 3
expect_count "$date_dir/params.txt" 3
expect_count "$date_dir/jsfiles.txt" 3
expect_count "$date_dir/dirs.txt" 3
expect_count "$date_dir/secrets.txt" 2
expect_count "$date_dir/dorks.txt" 2

auth_seed="$project_dir/auth.json"
cat > "$auth_seed" << 'EOF'
{
  "headers": {
    "Authorization": "Bearer SECRET_TOKEN"
  },
  "cookies": [
    {"name": "sid", "value": "SECRET_COOKIE", "url": "https://a.example.com"},
    {"name": "other", "value": "OTHER_COOKIE", "url": "https://other.example.com"}
  ]
}
EOF
chmod 600 "$auth_seed"

AUTH_SEED_FILE="$auth_seed"
AUTH_HOST="a.example.com"
AUTH_HEADERS=("X-CSRF-Token: CSRF_SECRET")
AUTH_COOKIES=("manual=COOKIE_SECRET")

auth_args="$(build_auth_args katana)"
if [[ "$auth_args" != *"Authorization: Bearer SECRET_TOKEN"* || "$auth_args" != *"Cookie: sid=SECRET_COOKIE"* || "$auth_args" == *"OTHER_COOKIE"* ]]; then
    echo "FAIL: auth args did not include only matching seed auth material"
    fail=1
else
    echo "PASS: auth args include matching seed auth material"
fi

passive_auth_args="$(build_auth_args subfinder)"
if [[ -n "$passive_auth_args" ]]; then
    echo "FAIL: passive tool unexpectedly received auth args"
    fail=1
else
    echo "PASS: passive tool did not receive auth args"
fi

ffuf_wordlist="$(resolve_ffuf_wordlist "")"
if [[ "$ffuf_wordlist" == "$SCRIPT_DIR/config/wordlists/dirs.lst" && -s "$ffuf_wordlist" ]]; then
    echo "PASS: ffuf resolves bundled fallback wordlist"
else
    echo "FAIL: ffuf fallback wordlist did not resolve"
    fail=1
fi

param_auth_args="$(build_auth_args param_recon)"
if [[ "$param_auth_args" != *"--auth-seed"* || "$param_auth_args" != *"--auth-header"* || "$param_auth_args" != *"--cookie"* ]]; then
    echo "FAIL: param_recon did not receive forwarded auth controls"
    fail=1
else
    echo "PASS: param_recon receives forwarded auth controls"
fi

param_command="$(get_tool_info param_recon command)"
rendered_param_command="$(apply_auth_args_to_command "$param_command" "$param_auth_args")"
if [[ "$rendered_param_command" == *"param_recon.sh"*"--auth-seed"*"&& cat"* && "$rendered_param_command" != *"&& cat"*"--auth-seed"* ]]; then
    echo "PASS: param_recon auth args are inserted into the script invocation"
else
    echo "FAIL: param_recon auth args were not inserted into the script invocation"
    fail=1
fi

redacted_command="$(redact_command "katana -H 'Authorization: Bearer SECRET_TOKEN' -H 'Cookie: sid=SECRET_COOKIE'")"
if [[ "$redacted_command" == *"SECRET_TOKEN"* || "$redacted_command" == *"SECRET_COOKIE"* ]]; then
    echo "FAIL: auth redaction leaked secret values"
    fail=1
else
    echo "PASS: auth redaction hides secret values"
fi

passive_profile_check="$(python3 - "$SCRIPT_DIR/config/profiles.yaml" "$SCRIPT_DIR/config/general.yaml" <<'PY'
import sys, yaml

profiles_path, general_path = sys.argv[1], sys.argv[2]
profiles = yaml.safe_load(open(profiles_path)) or {}
general = yaml.safe_load(open(general_path)) or {}
stages = profiles.get("profiles", {}).get("passive", {}).get("stages", [])
stage_defs = general.get("stages", {})

tools = []
for stage in stages:
    tools.extend(stage_defs.get(stage, {}).get("tools", []))

blocked_stages = {"alive_check", "http_fingerprinting", "dir_enum", "secret_scan"}
blocked_tools = {"httpx", "katana", "hakrawler", "xnlinkfinder", "gospider", "ffuf", "nuclei"}
bad_stages = sorted(blocked_stages.intersection(stages))
bad_tools = sorted(blocked_tools.intersection(tools))

if stages != ["passive_url_discovery", "passive_param_discovery", "passive_param_normalize"]:
    print("bad-stages-order:" + ",".join(stages))
elif bad_stages or bad_tools:
    print("blocked:" + ",".join(bad_stages + bad_tools))
else:
    print("ok")
PY
)"
if [[ "$passive_profile_check" != "ok" ]]; then
    echo "FAIL: passive profile includes live-touching stages/tools ($passive_profile_check)"
    fail=1
else
    echo "PASS: passive profile is archive/local only"
fi

if [[ "$fail" -ne 0 ]]; then
    echo ""
    echo "Self-test FAILED"
    exit 1
fi

echo ""
echo "Self-test PASSED"
