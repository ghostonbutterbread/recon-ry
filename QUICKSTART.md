# Quick Start

Get running with `recon-ry` in a few minutes.

## 1) Install Prerequisites

```bash
sudo apt update
sudo apt install -y curl jq git python3 python3-pip golang-go
pip3 install pyyaml
```

Add Go tools to `PATH`:

```bash
export PATH="$PATH:$(go env GOPATH)/bin"
```

## 2) Clone and Setup

```bash
git clone https://github.com/Ryushe/recon-ry
cd recon-ry
chmod +x main.sh

# Optional sanity check
./setup.sh

# Verify tool status
./main.sh check

# Install/update tools
./main.sh update
```

## 3) Initialize a Project

```bash
./main.sh init --project ~/bounties/example
```

This creates project inputs and `rate_limit.conf` (or regenerates config when seed files already exist).

## 4) Run a First Scan

```bash
./main.sh recon --full --project ~/bounties/example --url example.com -vv
```

## 5) Check Outputs

```bash
ls -la ~/bounties/example
ls -la ~/bounties/example/history
ls -la ~/bounties/example/eyewitness/history
```

Expected key paths:
- `wild.txt`, `urls.txt`, `alive.txt`, `params.txt`, `secrets.txt`
- `dirs_status/*.txt` (ffuf results split by status code)
- `history/<m-d-YYYY>/...` (run deltas)
- `eyewitness/history/<m-d-YYYY>/{alive,params,custom_input}`

## Common Commands

```bash
# Full recon
./main.sh recon --full --project ~/projects/target --url target.com

# Subdomain only
./main.sh recon --subs --project ~/projects/target --url target.com

# Fast profile (subs + alive)
./main.sh recon --fast --project ~/projects/target --url target.com

# URL discovery + alive (requires wild.txt)
./main.sh recon --urls --project ~/projects/target

# EyeWitness only (existing project inputs)
./main.sh recon --project ~/projects/target --eye

# EyeWitness with direct input
./main.sh recon --project ~/projects/target --eye https://app.target.com
./main.sh recon --project ~/projects/target --eye ~/targets/alive.txt

# Secret scan workflow
./main.sh secrets --project ~/projects/target

# Directory enum only
./main.sh recon --dir --project ~/projects/target

# Dry run
./main.sh recon --full --project ~/projects/target --url target.com --dry-run
```

## Background Dir Scan Management

```bash
# List background scans
./main.sh scans --project ~/projects/target

# Stop background scans
./main.sh scans --project ~/projects/target --kill
```

## Verbosity and Timeouts

```bash
# Verbose
./main.sh recon --subs --url example.com -v

# Very verbose
./main.sh recon --subs --url example.com -vv

# Override per-tool timeout for this run (0 = no timeout)
./main.sh recon --full --project ~/projects/target --timeout 600
```

## Troubleshooting

```bash
# Check install status
./main.sh check

# Validate config syntax
python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('config/profiles.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('config/install.yaml'))"

# Run offline self-test
./main.sh selftest
```

## Next

- Full reference: [README.md](README.md)
- Usage scenarios: [EXAMPLES.md](EXAMPLES.md)
