# Claude Recon Framework

A modular, extensible reconnaissance framework for bug bounty hunting and security research. Built with bash for maximum CLI tool compatibility and ease of customization.

## Features

- **Modular Architecture**: Easy to add, remove, or modify tools
- **Config-Driven**: All tools and stages defined in YAML configuration files
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
# Full reconnaissance on a domain
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
claude-recon/
├── main.sh                 # Main entry point
├── src/
│   ├── config.sh          # Config parsing and management
│   ├── stages.sh          # Stage execution logic
│   ├── tools.sh           # Tool runner and execution
│   ├── output.sh          # File handling and anew integration
│   ├── logger.sh          # Logging with verbosity levels
│   ├── updater.sh         # Tool installation and updates
│   └── tui.sh             # Interactive text user interface
├── config/
│   ├── general.yaml       # Tool and stage definitions
│   ├── profiles.yaml      # Scan profile configurations
│   └── install.yaml       # Tool installation info
└── README.md
```

## Configuration

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

All results are saved in the project directory:

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

### Example 1: Full Scan with Project Directory

```bash
./main.sh recon --full -vv --project $HOME/bounties/hackerone --url hackerone.com
```

Output:
```
[*] Starting recon with profile: full
[*] Project directory: /home/user/bounties/hackerone
[*] Target: hackerone.com
[*] Stages to run: subdomain_enum url_discovery alive_check get_ips port_enrichment http_fingerprinting param_discovery dir_enum secret_scan url_ranking
[*] History directory: /home/user/bounties/hackerone/history/20260210_143052
[*] Running stage: subdomain_enum
[+] Tool subfinder found 23 new entries
[+] Tool crt_sh found 15 new entries
...
[*] Results Summary:
  wild.txt       : 157 entries
  urls.txt       : 1243 entries
  alive.txt      : 89 entries
  httpx.jsonl    : 89 entries
  review_queue.jsonl: 89 entries
  params.txt     : 456 entries
```

### Example 2: Resume Scan with Existing Data

```bash
# If wild.txt already exists, skip subdomain enum
./main.sh recon --full --project $HOME/bounties/hackerone
```

### Example 3: Single URL to Stdout

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

### Example 4: Custom Profile

```bash
# Only run subdomain enum and alive check
./main.sh recon --profile fast --project $HOME/bounties/example --url example.com
```

### Example 5: Dry Run

```bash
# Preview what would run without executing
./main.sh recon --full --project $HOME/bounties/example --url example.com --dry-run
```

### Example 6: Google Dorking

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
