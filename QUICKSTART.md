# Quick Start Guide

Get up and running with Claude Recon Framework in 5 minutes!

## Installation

```bash
# Clone repository
git clone https://github.com/yourusername/claude-recon.git
cd claude-recon

# Run setup (checks dependencies)
./setup.sh

# Install reconnaissance tools
./main.sh update
```

## First Scan

### Option 1: Quick Test (No Project Directory)

```bash
# Subdomain enumeration to stdout
./main.sh recon --subs --url example.com
```

Output goes directly to terminal.

### Option 2: Full Scan with Project Directory

```bash
# Create project and run full scan
./main.sh recon --full --project ~/recon/example --url example.com
```

Results saved to:
- `~/recon/example/wild.txt` - Subdomains
- `~/recon/example/urls.txt` - All URLs
- `~/recon/example/alive.txt` - Live hosts
- `~/recon/example/params.txt` - URLs with parameters
- `~/recon/example/history/TIMESTAMP/` - Historical snapshot

## Common Commands

```bash
# Full reconnaissance
./main.sh recon --full --project ~/projects/target --url target.com

# Subdomain enumeration only
./main.sh recon --subs --project ~/projects/target --url target.com

# Secret scanning
./main.sh secrets --project ~/projects/target

# Check which tools are installed
./main.sh check

# Update all tools
./main.sh update

# Configure tools (interactive menu)
./main.sh enable_tools

# Configure stages (interactive menu)
./main.sh set_stages
```

## Verbosity Levels

```bash
# Default (quiet)
./main.sh recon --url example.com

# Verbose (show tool names and progress)
./main.sh recon --url example.com -v

# Very verbose (show all tool output)
./main.sh recon --url example.com -vv
```

## Profiles

Built-in profiles:

- `--full` - Complete reconnaissance (default)
- `--subs` - Subdomain enumeration only
- `--secrets` - Secret scanning
- `--dork` - Google dorking
- `--profile fast` - Quick scan (subs + alive check)

Example:
```bash
./main.sh recon --profile fast --project ~/recon/target --url target.com
```

## Workflow Examples

### Bug Bounty Initial Recon

```bash
# Day 1: Full scan
PROJECT=~/bounties/target
./main.sh recon --full -v --project $PROJECT --url target.com

# View results
cat $PROJECT/wild.txt        # Subdomains
cat $PROJECT/alive.txt       # Live hosts
cat $PROJECT/params.txt      # Parameters

# Day 2: Re-scan for new assets (anew handles deduplication)
./main.sh recon --full -v --project $PROJECT --url target.com
```

### Focused Scanning

```bash
# Only discover URLs from known subdomains
echo "api.target.com" > ~/recon/wild.txt
./main.sh recon --profile urls --project ~/recon
```

### Test Before Running

```bash
# Dry-run mode (see what would execute)
./main.sh recon --dry-run --full --project ~/test --url example.com
```

## Interactive Configuration

### Enable/Disable Tools

```bash
./main.sh enable_tools
```

Navigate with arrow keys:
- **Space** - Toggle tool on/off
- **Enter** - Save changes
- **Esc** - Cancel

### Configure Stages

```bash
./main.sh set_stages
```

Select which stages to run and whether they should execute in parallel.

## Troubleshooting

### Tools Not Found

```bash
# Add Go bin to PATH
export PATH=$PATH:$(go env GOPATH)/bin
echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
source ~/.bashrc

# Re-install tools
./main.sh update
```

### No Results

```bash
# Check if tools are working
./main.sh check

# Test individual tool
subfinder -d example.com

# Use verbose mode
./main.sh recon --subs -vv --url example.com
```

### Configuration Errors

```bash
# Validate YAML syntax
python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))"
```

## File Structure

```
~/recon/project/
├── wild.txt              # Discovered subdomains
├── urls.txt              # All URLs (subs + crawled)
├── alive.txt             # Live hosts
├── params.txt            # URLs with parameters
├── dirs.txt              # Discovered directories
├── secrets.txt           # Found secrets
└── history/
    └── 20260210_143052/  # Timestamped snapshot
        ├── wild.txt
        ├── urls.txt
        └── ...
```

## Next Steps

1. **Read the full documentation**: [README.md](README.md)
2. **See real-world examples**: [EXAMPLES.md](EXAMPLES.md)
3. **Learn to add tools**: [CONTRIBUTING.md](CONTRIBUTING.md)
4. **Customize configs**: Edit `config/*.yaml` files
5. **Config defaults**: Missing configs are restored from `config/defaults/`; `config/state.yaml` is user-specific and auto-created

## Tips

1. **Start small**: Begin with `--subs` before running `--full`
2. **Use dry-run**: Test with `--dry-run` first
3. **Monitor progress**: Use `-v` or `-vv` for visibility
4. **Incremental scans**: Re-running adds only new findings (via anew)
5. **Custom profiles**: Create your own in `config/profiles.yaml`

## Help

```bash
# Show help
./main.sh --help

# Get tool status
./main.sh check
```

For issues or questions, check [README.md](README.md) or open an issue on GitHub.

Happy Hunting! 🎯
