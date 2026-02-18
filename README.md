# Claude Recon Framework

A modular, extensible reconnaissance framework for bug bounty hunting and security research. Built with bash for maximum CLI tool compatibility and ease of customization.

## Features

- **Project Init**: Interactive setup — paste URL and subdomain lists directly into the terminal, auto-generates a per-project rate limit config
- **Modular Architecture**: Easy to add, remove, or modify tools
- **Config-Driven**: All tools and stages defined in YAML configuration files
- **Per-Project Rate Limiting**: `rate_limit.conf` overrides global limits per project; falls back to `general.yaml` when absent
- **Interactive TUI**: Enable/disable tools and configure stages with arrow keys
- **Smart Execution**: Sequential or parallel execution based on tool dependencies
- **History Tracking**: All scan results saved with timestamps
- **Profile System**: Pre-defined and custom scan profiles (full, subs, secrets, etc.)
- **Auto-Update**: Check and update all tools with a single command
- **Flexible Output**: Results to project directory or stdout
- **Dry-Run Mode**: Preview what will be executed without running

## Installation

### Prerequisites

```bash
# Install system dependencies
sudo apt install -y curl jq git python3 python3-pip golang-go

# Install PyYAML for config parsing
pip3 install pyyaml
```

### Clone and Setup

```bash
git clone https://github.com/yourusername/claude-recon.git
cd claude-recon
chmod +x main.sh

# Check tool installation status
./main.sh check

# Install missing tools
./main.sh update
```

## Quick Start

```bash
# 1. Initialize a new project (paste your target lists, generates rate_limit.conf)
./main.sh init --project ~/bounties/example

# 2. Full reconnaissance on a domain
./main.sh recon --full -vv --project ~/bounties/example --url example.com

# Subdomain enumeration only
./main.sh recon --subs -v --project ~/bounties/example --url example.com

# Run secrets scan on existing data
./main.sh secrets --project ~/bounties/example

# Quick scan to stdout (no project directory)
./main.sh recon --url example.com

# Configure which tools to use
./main.sh enable_tools

# Configure which stages to run
./main.sh set_stages
```

## Usage

### Commands

- `init` - Initialize a new project directory (paste-box input, generates rate_limit.conf)
- `recon` - Run reconnaissance based on profile
- `secrets` - Run secret scanning operations
- `enable_tools` - Interactive TUI to enable/disable tools
- `set_stages` - Interactive TUI to configure stages
- `update` - Update all installed tools
- `check` - Check tool installation status

### Options

- `--profile <name>` - Profile to run (default: full)
- `--full` - Shorthand for --profile full
- `--subs` - Shorthand for --profile subs
- `--secrets` - Shorthand for --profile secrets
- `--dork` - Shorthand for --profile dork
- `--project <dir>` - Project directory path
- `--url <url>` - Single URL/domain to scan
- `-v` - Verbose output (show tool names)
- `-vv` - Very verbose (show full tool output)
- `--dry-run` - Show what would be executed without running
- `--update` - Update tools before running
- `-h, --help` - Show help message

## Project Structure

```
recon-ry/
├── main.sh                 # Main entry point
├── src/
│   ├── init.sh            # Project initialization (paste-box, rate_limit.conf)
│   ├── config.sh          # Config parsing and management
│   ├── stages.sh          # Stage execution logic
│   ├── tools.sh           # Tool runner and execution
│   ├── output.sh          # File handling and anew integration
│   ├── logger.sh          # Logging with verbosity levels
│   ├── updater.sh         # Tool installation and updates
│   └── tui.sh             # Interactive text user interface
├── config/
│   ├── general.yaml       # Tool and stage definitions, global rate limits
│   ├── profiles.yaml      # Scan profile configurations
│   ├── install.yaml       # Tool installation info
│   ├── state.yaml         # User-specific tool/stage enablement (auto-created)
│   └── defaults/          # Config defaults used to restore missing files
└── README.md
```

A project directory (created by `init`) looks like:

```
~/bounties/example/
├── urls.txt               # Target URLs
├── wild.txt               # Subdomains / wildcard scope
├── alive.txt              # Live hosts (httpx output)
├── params.txt             # URLs with parameters
├── dirs.txt               # Discovered directories
├── secrets.txt            # Found secrets and sensitive data
├── rate_limit.conf        # Per-project rate limit overrides
└── history/
    └── 20260217_143052/   # Timestamped snapshot of each run
```

## Project Initialization

The `init` command sets up a project directory interactively before your first scan.

```bash
./main.sh init --project ~/bounties/example
```

## Config Defaults And State

On first run, any missing config files are restored from `config/defaults/`. The user-specific `config/state.yaml` is not tracked and will be created automatically if it doesn't exist.

It walks through two paste boxes — one for `urls.txt` and one for `wild.txt` — where you can paste your target scope directly from the clipboard. Press `Ctrl+D` on an empty line to save each one.

```
[*] Initializing project: ~/bounties/example

  ╔══════════════════════════════════════════════════════════════╗
  ║  Target URLs  (urls.txt)
  ║
  ║  Paste entries below, one per line.
  ║  Press Ctrl+D on an empty line when finished.
  ╚══════════════════════════════════════════════════════════════╝

https://example.com
https://api.example.com
^D

  ──────────────────────────────────────────────────────────────
[+] Saved 2 entries → ~/bounties/example/urls.txt
```

After both files are collected, `init` generates a `rate_limit.conf` pre-populated with the current global values from `general.yaml`. Edit that file to slow down (or speed up) specific tools for this target without touching global config.

If any file already exists with content, `init` asks before overwriting.

## Configuration

### Rate Limiting

Rate limits are configured at two levels:

**Global** — `config/general.yaml` (applies to all projects by default):

```yaml
defaults:
  rate_limit: 150   # fallback when a tool has no entry

rate_limits:
  subfinder: 150
  amass: 100
  ffuf: 150
  # ...
```

**Per-project** — `<project>/rate_limit.conf` (generated by `init`, takes full precedence):

```ini
# Values in requests per second
default=150

subfinder=150
amass=50        # slow amass down for this target
ffuf=30         # conservative fuzzing rate
httpx=150
```

Resolution order when a tool's rate limit is needed:

1. Tool entry in `rate_limit.conf` (if present and non-empty)
2. `default=` in `rate_limit.conf` (if tool entry is missing or blank)
3. `general.yaml` `rate_limits` / `defaults.rate_limit` (only when no `rate_limit.conf` exists)

To revert a project to global limits, delete `rate_limit.conf`.

### Profiles

Profiles define which stages to run. Edit `config/profiles.yaml` to create custom profiles:

```yaml
profiles:
  full:
    description: "Full reconnaissance scan"
    stages:
      - subdomain_enum
      - url_discovery
      - alive_check
      - param_discovery
      - dir_enum
      - secret_scan

  custom:
    description: "My custom profile"
    stages:
      - subdomain_enum
      - alive_check
```

### Stages

Stages group related tools together. Edit `config/general.yaml`:

```yaml
stages:
  subdomain_enum:
    enabled: true
    parallel: true  # Run tools in parallel
    description: "Subdomain enumeration"
    tools:
      - subfinder
      - crt_sh
      - assetfinder
```

### Tools

Each tool is defined with its command template and dependencies:

```yaml
tools:
  subfinder:
    enabled: true
    command: "subfinder -d {{DOMAIN}} -all -silent -o {{OUTPUT}}"
    required_files: []  # No input files needed
    outputs: [wild.txt]

  httpx:
    enabled: true
    command: "httpx -list {{INPUT}} -silent -o {{OUTPUT}}"
    required_files: [urls.txt]  # Requires urls.txt to exist
    outputs: [alive.txt]
```

### Tool Installation

Define how tools are installed in `config/install.yaml`:

```yaml
tools:
  subfinder:
    install_method: go
    install_command: "go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    update_check: "github:projectdiscovery/subfinder"
    binary_name: subfinder
```

## Adding New Tools

1. Add tool to `config/install.yaml`:

```yaml
tools:
  mytool:
    install_method: go
    install_command: "go install github.com/author/mytool@latest"
    update_check: "github:author/mytool"
    binary_name: mytool
```

2. Add tool definition to `config/general.yaml`:

```yaml
tools:
  mytool:
    enabled: true
    command: "mytool -input {{INPUT}} -output {{OUTPUT}}"
    required_files: [urls.txt]
    outputs: [mytool_results.txt]
```

3. Add tool to a stage in `config/general.yaml`:

```yaml
stages:
  url_discovery:
    enabled: true
    parallel: false
    tools:
      - katana
      - mytool  # Add here
```

4. Install the tool:

```bash
./main.sh update
```

## Workflow

### Full Scan Workflow

1. **Subdomain Enumeration** → `wild.txt`
   - subfinder, crt.sh, assetfinder, amass

2. **URL Discovery** → `urls.txt`
   - katana, hakrawler, waybackurls, gau

3. **Alive Check** → `alive.txt`
   - httpx (filters live hosts)

4. **Parameter Discovery** → `params.txt`
   - gau (with parameters) → uro (deduplication)

5. **Directory Enumeration** → `dirs.txt`
   - ffuf, dirsearch

6. **Secret Scanning** → `secrets.txt`
   - nuclei, trufflehog

## Examples

### Example 1: Initialize and Run a Full Scan

```bash
# Set up the project — paste scope lists, get rate_limit.conf
./main.sh init --project ~/bounties/example

# Run full recon
./main.sh recon --full -vv --project ~/bounties/example --url example.com
```

### Example 3: Full Scan with Project Directory

```bash
./main.sh recon --full -vv --project $HOME/bounties/hackerone --url hackerone.com
```

Output:
```
[*] Starting recon with profile: full
[*] Project directory: /home/user/bounties/hackerone
[*] Target: hackerone.com
[*] Stages to run: subdomain_enum url_discovery alive_check param_discovery dir_enum secret_scan
[*] History directory: /home/user/bounties/hackerone/history/20260210_143052
[*] Running stage: subdomain_enum
[+] Tool subfinder found 23 new entries
[+] Tool crt_sh found 15 new entries
...
[*] Results Summary:
  wild.txt       : 157 entries
  urls.txt       : 1243 entries
  alive.txt      : 89 entries
  params.txt     : 456 entries
```

### Example 4: Resume Scan with Existing Data

```bash
# If wild.txt already exists, skip subdomain enum
./main.sh recon --full --project $HOME/bounties/hackerone
```

### Example 5: Single URL to Stdout

```bash
./main.sh recon --url example.com

# Output printed to terminal
=== Results ===

=== wild.txt ===
example.com
www.example.com
mail.example.com
...
```

### Example 6: Custom Profile

```bash
# Only run subdomain enum and alive check
./main.sh recon --profile fast --project $HOME/bounties/example --url example.com
```

### Example 7: Dry Run

```bash
# Preview what would run without executing
./main.sh recon --full --project $HOME/bounties/example --url example.com --dry-run
```

### Example 8: Google Dorking

```bash
./main.sh secrets --dork --project $HOME/bounties/example
```

## Interactive Configuration

### Enable/Disable Tools

```bash
./main.sh enable_tools
```

This opens an interactive menu:

```
╔══════════════════════════════════════════════════════════════╗
║ Tool Configuration
╚══════════════════════════════════════════════════════════════╝

Use arrow keys to navigate, Space to toggle, Enter to save

> [✓] subfinder
  [✓] httpx
  [✓] katana
  [ ] amass
  [✓] nuclei
  ...

Controls: ↑/↓ Navigate | Space Select/Deselect | Enter Save | Esc Cancel
```

### Configure Stages

```bash
./main.sh set_stages
```

Select which stages to enable and configure parallel execution.

## Tips and Best Practices

1. **Start with subdomain enumeration**: Always begin with `--subs` to build your target list
2. **Use -vv for debugging**: See full tool output when troubleshooting
3. **Dry-run before big scans**: Use `--dry-run` to verify your configuration
4. **Regular updates**: Run `./main.sh update` weekly to keep tools current
5. **Custom profiles**: Create task-specific profiles for different hunting scenarios
6. **Resume scans**: If a scan fails, just re-run - anew will skip duplicates
7. **History tracking**: Check `history/` directories to see scan evolution

## Troubleshooting

### PyYAML not found

```bash
pip3 install pyyaml
```

### Tools not found after installation

```bash
# Ensure Go bin is in PATH
export PATH=$PATH:$(go env GOPATH)/bin

# Add to ~/.bashrc or ~/.zshrc
echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
```

### Permission denied

```bash
chmod +x main.sh
```

### Config parsing errors

```bash
# Validate YAML syntax
python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))"
```

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add your tool to the configs
4. Test thoroughly
5. Submit a pull request

## License

MIT License - See LICENSE file for details

## Credits

Built with contributions from the bug bounty and security research community.

Tools integrated:
- [ProjectDiscovery](https://github.com/projectdiscovery) - subfinder, httpx, katana, nuclei
- [Tom Hudson](https://github.com/tomnomnom) - waybackurls, anew, assetfinder
- [lc](https://github.com/lc) - gau
- [hakluke](https://github.com/hakluke) - hakrawler
- And many more!

## Support

For issues, questions, or feature requests, please open an issue on GitHub.

Happy Hunting! 🎯
