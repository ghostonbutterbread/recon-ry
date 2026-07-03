# recon-ry

A modular Bash reconnaissance framework for bug bounty and web attack-surface mapping.

## Features

- YAML-driven stages, tools, and profiles
- Project mode and single-URL mode
- Incremental output merging with `anew`
- Date-based history snapshots for new findings
- Interactive TUIs for enabling/disabling tools and stages
- Per-project `rate_limit.conf` (including per-tool timeout override)
- Background directory enumeration support
- EyeWitness integration with per-run history directories
- Dry-run mode and configurable verbosity (`-v`, `-vv`)
- Built-in offline self-test (`selftest`)

## Installation

### Prerequisites

```bash
sudo apt update
sudo apt install -y curl jq git python3 python3-pip golang-go
pip3 install pyyaml
```

Ensure Go binaries are in your `PATH`:

```bash
export PATH="$PATH:$(go env GOPATH)/bin"
```

### Setup

```bash
git clone https://github.com/Ryushe/recon-ry
cd recon-ry
chmod +x main.sh

# Optional dependency/config check
./setup.sh

# Check installed tools
./main.sh check

# Install/update tools and wordlists
./main.sh update
```

## Quick Start

```bash
# 1) Initialize project files and generate rate_limit.conf
./main.sh init --project ~/bounties/example

# 2) Run full recon
./main.sh recon --full --project ~/bounties/example --url example.com -vv

# 3) Review outputs
ls -la ~/bounties/example
ls -la ~/bounties/example/history
```

## Commands

- `init` - initialize a project directory and generate `rate_limit.conf`
- `recon` - run reconnaissance profiles/stages
- `secrets` - run secret-scanning workflow
- `eye_chunks` - run EyeWitness in recoverable chunks and merge one report
- `scans` - list/kill background scans (currently used for `dir_enum` background jobs)
- `enable_tools` - interactive tool toggle menu
- `set_stages` - interactive stage toggle/parallel menu
- `selftest` - run offline history/baseline self-test
- `check` - check tool installation status
- `update` - install/update configured tools

Run help:

```bash
./main.sh --help
./main.sh recon --help
./main.sh secrets --help
```

## Recon Options

- `--profile <name>`
- `--full`, `--subs`, `--fast`, `--urls`, `--passive`, `--dork`, `--eye [url|file]`
- `--dir` (directory enumeration only)
- `--project <dir>`
- `--url <url-or-domain>`
- `--timeout <secs>` (`0` disables timeout)
- `--auth-seed <file>` (owner-only JSON auth seed for supported active HTTP tools)
- `--auth-header <header>` (repeatable manual header for supported active HTTP tools)
- `--cookie <value>` (repeatable manual cookie header value for supported active HTTP tools)
- `--dry-run`
- `-v`, `-vv`

Notes:
- Either `--project` or `--url` must be provided.
- `wild.txt` and `urls.txt` are treated as read-only inputs during recon runs.
- In project mode, results and deltas are saved under date-based history directories.
- Auth is opt-in. It is only applied to active HTTP-capable tools: katana, httpx, HTTP fingerprinting, param_recon's Katana path, ffuf, and nuclei.
- Passive recon, DNS/IP enrichment, naabu, dorking, and local filesystem secret scanning stay unauthenticated.

## Authenticated Recon

Authenticated recon is designed for owned test-account lanes. Prefer passing an
auth seed created by the wrapper/account-management flow:

```bash
./main.sh recon --url https://example.com --project ~/bounties/example --urls --auth-seed ~/bounties/example/.auth/recon-ry-auth.json
```

For one-off approved tests, headers and cookies can be passed manually:

```bash
./main.sh recon --url https://example.com --project ~/bounties/example --params \
  --auth-header 'Authorization: Bearer REDACTED' \
  --cookie 'sid=REDACTED'
```

When `RECON_RY_AUTH_HOST` is set, cookie entries from an auth seed are filtered
to that host/domain before being handed to supported tools. Debug logging
redacts `-H`, `--auth-header`, and `--cookie` values.

## Built-in Profiles

Defined in `config/profiles.yaml`:

- `full`: `subdomain_enum`, `url_discovery`, `alive_check`, `get_ips`, `port_enrichment`, `http_fingerprinting`, `param_discovery`, `dir_enum`, `secret_scan`, `url_ranking`, `eyewitness`
- `subs`: `subdomain_enum`
- `fast`: `subdomain_enum`, `alive_check`
- `urls`: `url_discovery`, `alive_check`
- `passive`: `passive_url_discovery`, `passive_param_discovery`, `passive_param_normalize`
- `secrets`: `secret_scan`
- `dork`: `dork`
- `eye`: `eyewitness`
- `fingerprint`: `get_ips`, `port_enrichment`, `http_fingerprinting`, `url_ranking`

EyeWitness stage is forced to run last when present.

## Project Structure

```text
~/bounties/example/
├── urls.txt
├── wild.txt
├── alive.txt
├── params_raw.txt
├── params.txt
├── jsfiles.txt
├── ips.txt
├── hosts.jsonl
├── httpx_ip_raw.txt
├── naabu.jsonl
├── ports.txt
├── httpx.jsonl
├── waf_hosts.txt
├── unprotected_hosts.txt
├── review_queue.jsonl
├── secrets.txt
├── rate_limit.conf
├── dirs_status/
│   ├── 200.txt
│   ├── 301.txt
│   └── 403.txt
├── history/
│   └── 2-27-2026/
│       ├── alive.txt
│       ├── params.txt
│       ├── secrets.txt
│       └── dirs_status/
└── eyewitness/
    └── history/
        └── 2-27-2026/
            ├── alive/
            ├── params/
            └── custom_input/
```

Date format used by history folders is `m-d-YYYY`.

## `init` Behavior

`init` creates project scaffolding and writes a project-local `rate_limit.conf` from current `config/general.yaml` defaults.

Current behavior:
- If either `urls.txt` or `wild.txt` already exists, paste prompts are skipped and only config generation runs.
- If `rate_limit.conf` exists, you are prompted before overwrite.

Rate/timeout precedence at runtime:
1. `<project>/rate_limit.conf` tool-specific entry
2. `<project>/rate_limit.conf` `default=`
3. Global `config/general.yaml` defaults (when project file is absent)

`timeout=` in `rate_limit.conf` overrides global default timeout for that project.

## EyeWitness Behavior

- `recon --eye` (or profile `eye`) runs EyeWitness only.
- `--eye [url|file]` accepts either a single URL string or a file path.
- Output goes through the incremental EyeWitness wrapper by default.
- The default durable store is `eyewitness/`, configurable with the `tools.eyewitness.store_dir` value in `config/general.yaml`.
- The central report and URL lookup manifest are written to `eyewitness/final/report.html` and `eyewitness/final/requests.jsonl`.

`--full` + EyeWitness input selection:
- If `eyewitness/` does not exist or is empty, EyeWitness uses normal run/project `alive.txt` and `params.txt` inputs.
- If `eyewitness/` already has content, EyeWitness uses current run delta files from `history/<date>/alive.txt` and `history/<date>/params.txt`.

## Incremental EyeWitness Reports

Use `eye_chunks` for large screenshot/source farming runs where one native
EyeWitness process would be too fragile:

```bash
./main.sh eye_chunks \
  --input ~/bounties/example/alive.txt \
  --output ~/bounties/example/eyewitness \
  --chunk-size 4000 \
  --threads 1 \
  --timeout 10
```

The wrapper:

- treats `--output` as a durable EyeWitness store
- skips URLs already present in the store unless `--fresh` is used
- splits the input file into stable chunk files
- runs native EyeWitness once per chunk in an isolated per-run work directory
- keeps EyeWitness SQLite DBs under a local cache via `--db-root` so mounted output directories do not hit SQLite lock failures
- records chunk state under `runs/<run_id>/state/chunks.json`
- moves completed screenshots/source files into `final/screens/` and `final/source/`
- writes merged metadata to `final/requests.jsonl`
- writes the current run report to `runs/<run_id>/final/report.html`
- regenerates the central EyeWitness-style merged report at `final/report.html`
- optionally renders `final/report.pdf` with `--pdf` when Playwright is installed
- deletes successful chunk work directories after merge unless `--keep-work` is used

The same wrapper is also used by `recon --eye`; tune these defaults under
`tools.eyewitness` in `config/general.yaml`:

- `store_dir`
- `eyewitness_path`
- `eyewitness_python`
- `chunk_size`
- `threads`
- `eyewitness_timeout`
- `max_retries`

If a chunk fails, rerun only that chunk:

```bash
./main.sh eye_chunks \
  --input ~/bounties/example/alive.txt \
  --output ~/bounties/example/eyewitness \
  --resume \
  --only-chunk chunk_0007 \
  --force
```

For Hoster-sized runs, run this command inside `tmux` or `systemd-run --user`
on Hoster so OpenClaw restarts cannot terminate the capture process.

## Directory Enumeration Output

`ffuf` output is parsed and split by HTTP status code:
- Canonical results are written to `dirs_status/<status>.txt`
- History copies include `history/<date>/dirs_status/*.txt`

`dirs.txt` is used as an intermediate and removed after status-split processing.

## Background Scans

When `dir_enum` is included in profile flow, it is launched in the background after `alive_check`.

Manage it with:

```bash
./main.sh scans --project ~/bounties/example
./main.sh scans --project ~/bounties/example --kill
```

## Tooling and Config Files

- `config/general.yaml` - stages and tool command templates
- `config/profiles.yaml` - profile-to-stage mappings
- `config/install.yaml` - install/update metadata
- `config/payloads.yaml` - optional payload command overrides
- `config/state.yaml` - user toggles for tools/stages (auto-created)
- `config/defaults/*` - default config fallbacks

Missing config files are restored from `config/defaults/` when possible.

## Recon Pipeline

1. **Subdomain Enumeration** → `wild.txt`
   - subfinder, crt.sh, assetfinder, amass

2. **URL Discovery** → `urls.txt`
   - katana, hakrawler, waybackurls, gau

3. **Alive Check** → `alive.txt`
   - httpx (filters live hosts)

4. **IP Enrichment** → `ips.txt`, `hosts.jsonl`
   - extract and dedupe hosts from `urls.txt` plus `alive.txt`, then use httpx `-ip` with DNS fallback

5. **Port Enrichment** → `naabu.jsonl`, `ports.txt`
   - naabu fast port signal, controlled by config and run once per profile

6. **HTTP Fingerprinting** → `httpx.jsonl`, `waf_hosts.txt`, `unprotected_hosts.txt`
   - host-deduped httpx JSON facts for tech, CDN/WAF hints, status, title, and web server

7. **Parameter Discovery** → `params.txt`
   - gau (with parameters) → uro (deduplication)

8. **Directory Enumeration** → `dirs.txt`
   - ffuf, dirsearch

9. **Secret Scanning** → `secrets.txt`
   - nuclei, trufflehog

10. **URL Ranking** → `review_queue.jsonl`
    - ranked review queue for focused human and agent follow-up

### Output Files

- `wild.txt` - Discovered subdomains
- `urls.txt` - All URLs (subdomains + discovered URLs)
- `alive.txt` - Live hosts (filtered by httpx)
- `ips.txt` - Unique IPs extracted from the URL corpus
- `hosts.jsonl` - Host/IP metadata sidecar
- `httpx_ip_raw.txt` - Raw httpx `-ip` output used for IP extraction when available
- `naabu.jsonl` - Naabu JSON port results
- `ports.txt` - Compact open-port sidecar
- `httpx.jsonl` - HTTP fingerprinting JSON
- `waf_hosts.txt` - Hosts with CDN/WAF/protection hints
- `unprotected_hosts.txt` - Hosts without obvious CDN/WAF hints
- `params.txt` - URLs with parameters
- `dirs.txt` - Discovered directories
- `secrets.txt` - Found secrets and sensitive data
- `review_queue.jsonl` - Ranked targets and reasons for focused review
- `history/TIMESTAMP/` - Historical snapshots of each run

## Examples

```bash
# Full recon in project mode
./main.sh recon --full --project ~/bounties/example --url example.com -vv

# Use existing project data only
./main.sh recon --full --project ~/bounties/example

# EyeWitness only on existing alive/params inputs
./main.sh recon --project ~/bounties/example --eye

# EyeWitness with direct URL input
./main.sh recon --project ~/bounties/example --eye https://app.example.com

# EyeWitness with file input
./main.sh recon --project ~/bounties/example --eye ~/targets/alive.txt

# Incremental EyeWitness report for a large URL list
./main.sh eye_chunks --input ~/targets/alive.txt --output ~/bounties/example/eyewitness --chunk-size 4000

# Secrets workflow
./main.sh secrets --secrets --project ~/bounties/example

# Dry run
./main.sh recon --full --project ~/bounties/example --url example.com --dry-run

# Fingerprint and rank existing live hosts
./main.sh recon --profile fingerprint --project ~/bounties/example

# Offline health check
./main.sh selftest
```

## Troubleshooting

### PyYAML errors

```bash
pip3 install pyyaml
```

### Tools not found

```bash
export PATH="$PATH:$(go env GOPATH)/bin"
./main.sh check
./main.sh update
```

### Validate config syntax

```bash
python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('config/profiles.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('config/install.yaml'))"
```

## License

MIT. See `LICENSE`.
