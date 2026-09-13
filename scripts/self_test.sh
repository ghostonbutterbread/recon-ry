#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/src/logger.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/output.sh"
source "$SCRIPT_DIR/src/tools.sh"
source "$SCRIPT_DIR/src/stages.sh"

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
if [[ "$param_auth_args" != *"--auth-seed"* || "$param_auth_args" != *"--header"* || "$param_auth_args" != *"--cookie"* ]]; then
    echo "FAIL: param_recon did not receive forwarded auth controls"
    fail=1
else
    echo "PASS: param_recon receives forwarded auth controls"
fi

for header_tool in katana httpx ffuf nuclei; do
    tool_header_args="$(build_auth_args "$header_tool")"
    if [[ "$tool_header_args" != *"Authorization:"* || "$tool_header_args" != *"X-CSRF-Token:"* || "$tool_header_args" != *"Cookie:"* ]]; then
        echo "FAIL: $header_tool did not receive all authentication and custom headers"
        fail=1
    else
        echo "PASS: $header_tool receives authentication and custom headers"
    fi
done

header_aliases="$(python3 "$SCRIPT_DIR/scripts/auth_args.py" --format json --header 'Authorization: Bearer NEW' --auth-header 'X-Legacy: yes')"
if [[ "$header_aliases" != *'Authorization: Bearer NEW'* || "$header_aliases" != *'X-Legacy: yes'* ]]; then
    echo "FAIL: --header and --auth-header aliases were not both accepted"
    fail=1
else
    echo "PASS: --header and legacy --auth-header are both accepted"
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

original_general_config_json="$GENERAL_CONFIG_JSON"
GENERAL_CONFIG_JSON='{"tools":{"eyewitness":{"large_project_dir":"/mnt/bounty","store_dir":"{{PROJECT_DIR}}/eyewitness"}}}'
large_eye_store="$(resolve_eyewitness_store_dir "/tmp/reconry_selftest_acme" "app.example.com" "https://app.example.com")"
if [[ "$large_eye_store" == "/mnt/bounty/reconry_selftest_acme/web/recon/eyewitness" ]]; then
    echo "PASS: EyeWitness large_project_dir resolves to mounted store"
else
    echo "FAIL: EyeWitness large_project_dir resolved to $large_eye_store"
    fail=1
fi

GENERAL_CONFIG_JSON='{"tools":{"eyewitness":{"store_dir":"{{PROJECT_DIR}}/eyewitness"}}}'
legacy_eye_store="$(resolve_eyewitness_store_dir "/tmp/reconry_selftest_acme" "app.example.com" "https://app.example.com")"
if [[ "$legacy_eye_store" == "/tmp/reconry_selftest_acme/eyewitness" ]]; then
    echo "PASS: EyeWitness legacy store_dir remains project-local"
else
    echo "FAIL: EyeWitness legacy store_dir resolved to $legacy_eye_store"
    fail=1
fi
GENERAL_CONFIG_JSON='{"tools":{"eyewitness":{"large_project_dir":"/mnt/bounty","store_dir":"{{LARGE_PROJECT_DIR}}/archive/{{DOMAIN}}"}}}'
custom_eye_store="$(resolve_eyewitness_store_dir "/tmp/reconry_selftest_acme" "app.example.com" "https://app.example.com")"
if [[ "$custom_eye_store" == "/mnt/bounty/archive/app.example.com" ]]; then
    echo "PASS: EyeWitness custom store template resolves placeholders"
else
    echo "FAIL: EyeWitness custom store template resolved to $custom_eye_store"
    fail=1
fi
GENERAL_CONFIG_JSON="$original_general_config_json"

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

cached_report_dir="$project_dir/eyewitness-cache-test"
mkdir -p "$cached_report_dir/final"
cat > "$cached_report_dir/final/requests.jsonl" << 'EOF'
{"url":"https://a.example.com/","title":"A Home","category":"page","screenshot":"screens/a.png","source":"source/a.txt","run_id":"run1","chunk":"chunk_0001","headers":{"Content-Type":"text/html"}}
{bad-json
{"url":"https://a.example.com/app.js","title":"App JS","screenshot":"","source":"source/app.js.txt","run_id":"run1","chunk":"chunk_0001","headers":{"Content-Type":"application/javascript"}}
{"url":"https://a.example.com/admin","title":"Forbidden","category":"unauth","screenshot":"screens/admin.png","source":"source/admin.txt","run_id":"run1","chunk":"chunk_0001","headers":{"Content-Type":"text/html"}}
{"url":"https://b.example.com/","title":"Capture failed","category":"badhost","error":"DNS failed","screenshot":"","source":"","run_id":"run1","chunk":"chunk_0001","headers":{}}
EOF

cached_report_check="$("$SCRIPT_DIR/scripts/incremental_eyewitness.py" \
    --output "$cached_report_dir" \
    --report-only \
    --report-style cached \
    --title "Self Test EyeWitness Report" \
    --report-page-size 1 2>&1)"
if [[ ! -f "$cached_report_dir/final/report.html" \
    || ! -f "$cached_report_dir/final/report_cache.sqlite" \
    || ! -f "$cached_report_dir/final/assets/report-index.js" \
    || "$cached_report_check" != *"Central report:"* \
    || "$(grep -o '"url":"https://a.example.com' "$cached_report_dir/final/assets/report-index.js" | wc -l | tr -d ' ')" != "3" \
    || "$(grep -c 'Include / Exclude' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'Hide 403s' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'Hide Designs' "$cached_report_dir/final/report.html" || true)" != "0" \
    || "$(grep -c 'Hide URL pattern' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'Hide same response' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'TXT URLs' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'value="app-error"> Errors <span>1</span>' "$cached_report_dir/final/report.html")" != "1" \
    || "$(grep -c 'value="capture-error"> Capture Errors <span>1</span>' "$cached_report_dir/final/report.html")" != "1" ]]; then
    echo "FAIL: cached EyeWitness report did not render expected artifacts"
    echo "$cached_report_check"
    fail=1
else
    echo "PASS: cached EyeWitness report renders searchable artifacts"
fi

cached_run_report_check="$(python3 - "$SCRIPT_DIR/scripts/incremental_eyewitness.py" "$cached_report_dir" <<'PY'
import importlib.util
import sys
from pathlib import Path

module_path, store = sys.argv[1:]
spec = importlib.util.spec_from_file_location("incremental_eyewitness", module_path)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

store_dir = Path(store)
run_report_dir = store_dir / "runs" / "run1" / "final"
manifest = store_dir / "final" / "requests.jsonl"
mod.render_cached_report(run_report_dir, manifest, "Run report", 1, asset_prefix="../../../final/")
index = (run_report_dir / "assets" / "report-index.js").read_text(encoding="utf-8")
print("ok" if '"screenshot":"../../../final/screens/a.png"' in index and '"source":"../../../final/source/a.txt"' in index else "bad-run-asset-prefix")
PY
)"
if [[ "$cached_run_report_check" != "ok" ]]; then
    echo "FAIL: cached run report did not preserve central artifact links ($cached_run_report_check)"
    fail=1
else
    echo "PASS: cached run report preserves central artifact links"
fi

artifact_retry_check="$(python3 - "$SCRIPT_DIR/scripts/incremental_eyewitness.py" <<'PY'
import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

module_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("incremental_eyewitness", module_path)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp) / "work"
    final = Path(tmp) / "final"
    base.mkdir()
    src = base / ("source-" + "x" * 220 + ".html")
    src.write_text("artifact", encoding="utf-8")
    calls = []
    real_copy2 = shutil.copy2

    def flaky_copy2(source, dest, *args, **kwargs):
        calls.append(Path(dest).name)
        if len(calls) == 1:
            raise OSError("simulated filename failure")
        return real_copy2(source, dest, *args, **kwargs)

    old_copy2 = mod.shutil.copy2
    mod.shutil.copy2 = flaky_copy2
    try:
        rel = mod.copy_artifact(str(src), final, "source", "run__chunk_0001", base)
    finally:
        mod.shutil.copy2 = old_copy2

    copied = final / rel if rel else None
    if (
        rel
        and copied is not None
        and copied.read_text(encoding="utf-8") == "artifact"
        and len(calls) >= 2
        and len(calls[1].encode("utf-8")) < len(calls[0].encode("utf-8"))
    ):
        print("ok")
    else:
        print("artifact-retry-failed")
PY
)"
if [[ "$artifact_retry_check" != "ok" ]]; then
    echo "FAIL: EyeWitness artifact retry did not preserve artifact ($artifact_retry_check)"
    fail=1
else
    echo "PASS: EyeWitness artifact copy retries with shorter names"
fi

if [[ "$fail" -ne 0 ]]; then
    echo ""
    echo "Self-test FAILED"
    exit 1
fi

echo ""
echo "Self-test PASSED"
