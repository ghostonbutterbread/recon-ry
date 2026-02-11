# Claude Recon Framework - Examples

Practical examples and use cases for the Claude Recon Framework.

## Table of Contents

1. [Basic Usage](#basic-usage)
2. [Bug Bounty Workflow](#bug-bounty-workflow)
3. [Subdomain Takeover Hunting](#subdomain-takeover-hunting)
4. [Parameter Discovery for XSS](#parameter-discovery-for-xss)
5. [Secret Hunting](#secret-hunting)
6. [Continuous Monitoring](#continuous-monitoring)
7. [Custom Workflows](#custom-workflows)

---

## Basic Usage

### First Time Setup

```bash
# Clone and setup
git clone https://github.com/yourusername/claude-recon.git
cd claude-recon
./setup.sh

# Install tools
./main.sh update

# Verify installation
./main.sh check
```

### Quick Domain Scan

```bash
# Simple subdomain scan to stdout
./main.sh recon --subs --url example.com

# Full scan with project directory
./main.sh recon --full --project ~/recon/example --url example.com
```

---

## Bug Bounty Workflow

### Initial Reconnaissance

Day 1 - Discover the attack surface:

```bash
# Create project directory
PROJECT=~/bounties/hackerone
mkdir -p $PROJECT

# Full reconnaissance scan
./main.sh recon --full -vv --project $PROJECT --url hackerone.com

# Results saved to:
# - $PROJECT/wild.txt (subdomains)
# - $PROJECT/urls.txt (all URLs)
# - $PROJECT/alive.txt (live hosts)
# - $PROJECT/params.txt (parameters)
# - $PROJECT/history/TIMESTAMP/ (historical snapshot)
```

### Daily Monitoring

Day 2+ - Find new assets:

```bash
# Run scan again - anew will only show new findings
./main.sh recon --full -v --project $PROJECT --url hackerone.com

# Compare with previous scan
diff $PROJECT/history/20260210_100000/wild.txt $PROJECT/wild.txt

# Or use the latest vs previous
ls -t $PROJECT/history/ | head -2
```

### Focused Scanning

When you find an interesting subdomain:

```bash
# Focus on specific subdomain
./main.sh recon --full --url api.hackerone.com

# Just URL discovery for specific target
# Create urls.txt manually
echo "https://api.hackerone.com" > $PROJECT/urls.txt

# Run URL discovery stage only
./main.sh recon --profile urls --project $PROJECT
```

---

## Subdomain Takeover Hunting

### Workflow

```bash
PROJECT=~/recon/takeovers

# Step 1: Enumerate subdomains
./main.sh recon --subs -v --project $PROJECT --url target.com

# Step 2: Check which are alive
./main.sh recon --profile fast --project $PROJECT

# Step 3: Manual analysis
# Check alive.txt for interesting patterns:
cat $PROJECT/alive.txt | grep -E "(herokuapp|s3|cloudfront|github\.io)"

# Step 4: Use subjack or similar
cat $PROJECT/wild.txt | subjack -w - -o $PROJECT/takeovers.txt
```

---

## Parameter Discovery for XSS

### Find Parameters

```bash
PROJECT=~/xss-hunting/target

# Full scan to get parameters
./main.sh recon --full -vv --project $PROJECT --url target.com

# Analyze params.txt
cat $PROJECT/params.txt | grep -E "(redirect|url|next|return|callback|q|search)"

# Extract parameter names
cat $PROJECT/params.txt | sed 's/?.*//' | sort -u > $PROJECT/param_names.txt

# Use with XSS testing tools
cat $PROJECT/params.txt | qsreplace '"><svg/onload=alert(1)>' | airixss
```

### Pattern Matching

```bash
# Find URLs with interesting patterns
cat $PROJECT/urls.txt | grep -E "\.js$" > $PROJECT/js_files.txt
cat $PROJECT/urls.txt | grep -E "\.json$" > $PROJECT/json_endpoints.txt

# Find admin panels
cat $PROJECT/urls.txt | grep -E "(admin|dashboard|panel|login|console)" > $PROJECT/admin.txt
```

---

## Secret Hunting

### GitHub Dorking

```bash
PROJECT=~/secrets/company

# Run secret scan
./main.sh secrets --project $PROJECT

# Manual GitHub dorking
site:github.com "company.com" password
site:github.com "company.com" api_key
site:github.com "company.com" secret
site:github.com "company.com" token
```

### Configuration Files

```bash
# Find config files
cat $PROJECT/urls.txt | grep -E "\.(config|conf|cfg|ini|xml|yml|yaml|json)$" > $PROJECT/configs.txt

# Download and scan
while read url; do
    curl -s "$url" | grep -iE "(password|api_key|secret|token)"
done < $PROJECT/configs.txt
```

### JavaScript Analysis

```bash
# Extract all JS files
cat $PROJECT/urls.txt | grep "\.js$" > $PROJECT/js_files.txt

# Download and scan for secrets
mkdir -p $PROJECT/js
while read url; do
    filename=$(echo $url | md5sum | cut -d' ' -f1)
    curl -s "$url" > "$PROJECT/js/$filename.js"
done < $PROJECT/js_files.txt

# Scan with nuclei or trufflehog
nuclei -t ~/nuclei-templates/exposures/ -target $PROJECT/js/
trufflehog filesystem $PROJECT/js/ --json > $PROJECT/js_secrets.json
```

---

## Continuous Monitoring

### Cron Job Setup

Monitor for new subdomains daily:

```bash
# Create monitoring script
cat > ~/scripts/monitor_target.sh << 'EOF'
#!/bin/bash
PROJECT=~/bounties/target
./main.sh recon --full -v --project $PROJECT --url target.com

# Check for new findings
NEW_SUBS=$(cat $PROJECT/wild.txt | wc -l)
echo "Total subdomains: $NEW_SUBS"

# Notify (optional)
if command -v notify-send &> /dev/null; then
    notify-send "Recon Complete" "Found $NEW_SUBS subdomains for target.com"
fi
EOF

chmod +x ~/scripts/monitor_target.sh

# Add to crontab (daily at 2 AM)
crontab -e
# Add: 0 2 * * * /home/user/scripts/monitor_target.sh >> /home/user/logs/recon.log 2>&1
```

### Weekly Deep Scan

```bash
# Full deep scan with all tools enabled
./main.sh enable_tools  # Enable all tools in TUI

# Weekly full scan
0 3 * * 0 /home/user/scripts/weekly_deep_scan.sh
```

---

## Custom Workflows

### Create Custom Profile

For API testing:

```bash
# Edit config/profiles.yaml
cat >> config/profiles.yaml << 'EOF'
  api_testing:
    description: "API endpoint testing"
    stages:
      - url_discovery
      - alive_check
      - param_discovery
EOF

# Use custom profile
./main.sh recon --profile api_testing --project ~/api-testing --url api.example.com
```

### Add Custom Tool

Add a custom tool (e.g., custom script):

```bash
# 1. Create your tool
cat > ~/tools/custom_scanner.sh << 'EOF'
#!/bin/bash
cat "$1" | while read url; do
    echo "Scanning: $url"
    # Your custom logic here
done > "$2"
EOF
chmod +x ~/tools/custom_scanner.sh

# 2. Add to config/install.yaml
cat >> config/install.yaml << 'EOF'
  custom_scanner:
    install_method: git
    install_command: "# Already installed manually"
    binary_name: custom_scanner.sh
    binary_path: "~/tools/custom_scanner.sh"
EOF

# 3. Add to config/general.yaml
# Add under tools:
#   custom_scanner:
#     enabled: true
#     command: "~/tools/custom_scanner.sh {{INPUT}} {{OUTPUT}}"
#     required_files: [urls.txt]
#     outputs: [custom_results.txt]

# 4. Add to a stage
# Add to dir_enum or create new stage
```

### Disable Slow Tools

```bash
# Interactive TUI
./main.sh enable_tools
# Deselect amass or other slow tools

# Or manually edit config/general.yaml
# Set enabled: false for specific tools
```

### Parallel Everything

Speed up scans by enabling parallel execution:

```bash
# Interactive
./main.sh set_stages
# Enable parallel for all stages (use with caution - may hit rate limits)

# Or manually edit config/general.yaml
# Set parallel: true for stages
```

---

## Advanced Techniques

### Scope Management

```bash
# Create inscope.txt
cat > $PROJECT/inscope.txt << 'EOF'
*.example.com
example.com
api.example.com
EOF

# Filter results to scope
cat $PROJECT/wild.txt | grep -f $PROJECT/inscope.txt > $PROJECT/inscope_subs.txt
```

### Diff Mode

```bash
# Compare two scans
SCAN1=$PROJECT/history/20260210_100000
SCAN2=$PROJECT/history/20260210_120000

# New subdomains
comm -13 <(sort $SCAN1/wild.txt) <(sort $SCAN2/wild.txt) > new_subs.txt

# New URLs
comm -13 <(sort $SCAN1/urls.txt) <(sort $SCAN2/urls.txt) > new_urls.txt

echo "New subdomains: $(wc -l < new_subs.txt)"
echo "New URLs: $(wc -l < new_urls.txt)"
```

### Integration with Other Tools

```bash
# Export for nuclei
./main.sh recon --full --project $PROJECT --url example.com
nuclei -list $PROJECT/alive.txt -t ~/nuclei-templates/ -o $PROJECT/nuclei.txt

# Export for Burp Suite
cat $PROJECT/alive.txt  # Import to Burp target scope

# Export for manual testing
cat $PROJECT/params.txt | head -20  # Test top 20 params manually
```

### Notification Systems

#### Slack Notification

```bash
# Add to end of scan
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

SUBS=$(wc -l < $PROJECT/wild.txt)
URLS=$(wc -l < $PROJECT/urls.txt)

curl -X POST $SLACK_WEBHOOK -H 'Content-type: application/json' --data "{
  \"text\": \"Recon complete for example.com\",
  \"attachments\": [{
    \"fields\": [
      {\"title\": \"Subdomains\", \"value\": \"$SUBS\", \"short\": true},
      {\"title\": \"URLs\", \"value\": \"$URLS\", \"short\": true}
    ]
  }]
}"
```

#### Discord Notification

```bash
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR/WEBHOOK"

curl -X POST $DISCORD_WEBHOOK \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"Recon complete: $SUBS subdomains, $URLS URLs\"}"
```

---

## Performance Tips

1. **Start Small**: Begin with `--subs` then expand to `--full`
2. **Use Parallel**: Enable parallel execution for independent tools
3. **Disable Slow Tools**: Turn off amass or other slow tools for quick scans
4. **Use Filters**: Filter to scope early to reduce processing time
5. **Incremental Scans**: Use existing data, anew handles deduplication
6. **Resource Limits**: Be mindful of rate limits and API quotas

## Troubleshooting Examples

### No Results

```bash
# Verify tools are working
./main.sh check

# Test individual tool
subfinder -d example.com -silent

# Use verbose mode
./main.sh recon --subs -vv --url example.com
```

### Too Many Results

```bash
# Filter to interesting subdomains only
cat $PROJECT/wild.txt | grep -vE "(test|dev|staging)" > $PROJECT/prod_subs.txt

# Limit to recent changes
ls -t $PROJECT/history/ | head -1
```

---

## Real-World Examples

### Example 1: Private Bug Bounty Program

```bash
# Initial scan
./main.sh recon --full -vv --project ~/bb/acme --url acme.com

# Results:
# - 342 subdomains
# - 15,234 URLs
# - 2,134 live hosts
# - 456 URLs with parameters

# Focus on API endpoints
cat ~/bb/acme/urls.txt | grep "/api/" > ~/bb/acme/api_endpoints.txt

# Test for IDOR
# (manual testing with Burp)
```

### Example 2: Subdomain Monitoring

```bash
# Week 1
./main.sh recon --subs --project ~/monitoring/target --url target.com
# Found: 150 subdomains

# Week 2
./main.sh recon --subs --project ~/monitoring/target --url target.com
# Found: 152 subdomains (2 new!)

# Check what's new
# New subdomains automatically added via anew
```

---

Happy Hunting! 🎯

For more information, see [README.md](README.md)
