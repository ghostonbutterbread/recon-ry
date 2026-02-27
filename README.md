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
- `--full`, `--subs`, `--fast`, `--urls`, `--dork`, `--eye [url|file]`
- `--dir` (directory enumeration only)
- `--project <dir>`
- `--url <url-or-domain>`
- `--timeout <secs>` (`0` disables timeout)
- `--dry-run`
- `-v`, `-vv`

Notes:
- Either `--project` or `--url` must be provided.
- `wild.txt` and `urls.txt` are treated as read-only inputs during recon runs.
- In project mode, results and deltas are saved under date-based history directories.

## Built-in Profiles

Defined in `config/profiles.yaml`:

- `full`: `subdomain_enum`, `url_discovery`, `alive_check`, `param_discovery`, `dir_enum`, `secret_scan`, `eyewitness`
- `subs`: `subdomain_enum`
- `fast`: `subdomain_enum`, `alive_check`
- `urls`: `url_discovery`, `alive_check`
- `secrets`: `secret_scan`
- `dork`: `dork`
- `eye`: `eyewitness`

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
- Output goes to `eyewitness/history/<date>/custom_input` for custom input, and to `.../alive` / `.../params` for list-based inputs.

`--full` + EyeWitness input selection:
- If `eyewitness/` does not exist or is empty, EyeWitness uses normal run/project `alive.txt` and `params.txt` inputs.
- If `eyewitness/` already has content, EyeWitness uses current run delta files from `history/<date>/alive.txt` and `history/<date>/params.txt`.

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

# Secrets workflow
./main.sh secrets --secrets --project ~/bounties/example

# Dry run
./main.sh recon --full --project ~/bounties/example --url example.com --dry-run

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
