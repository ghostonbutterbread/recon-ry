# Tool Types Guide

The framework now supports three types of tools, making it easy to integrate any kind of recon tool.

## Tool Types

### 1. Binary Tools
**What**: Standalone binary applications that need to be installed

**Examples**: subfinder, httpx, katana, nuclei

**Config**:
```yaml
# config/general.yaml
tools:
  subfinder:
    enabled: true
    type: binary  # Requires binary installation
    command: "subfinder -d {{DOMAIN}} -all -silent -o {{OUTPUT}}"
    required_files: []
    outputs: [wild.txt]
```

```yaml
# config/install.yaml
tools:
  subfinder:
    install_method: go
    install_command: "go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    binary_name: subfinder
```

**How it works**:
- Framework checks if binary exists: `command -v subfinder`
- Can be installed via: `./main.sh update`
- Shows as ✓ or ✗ in `./main.sh check`

---

### 2. Inline Commands
**What**: Commands built from shell utilities (curl, jq, grep, etc.)

**Examples**: crt_sh, custom API queries, one-liners

**Config**:
```yaml
# config/general.yaml
tools:
  crt_sh:
    enabled: true
    type: inline  # Not a binary, just a command
    command: "curl -s 'https://crt.sh/?q=%25.{{DOMAIN}}&output=json' | jq -r '.[].name_value' | sed 's/*.//g' | sort -u"
    required_files: []
    outputs: [wild.txt]
```

```yaml
# config/install.yaml
tools:
  crt_sh:
    install_method: inline
    install_command: "# Uses curl and jq - no installation needed"
    binary_name: crt_sh
    dependencies: [curl, jq]  # Optional: list what it needs
```

**How it works**:
- No binary check needed
- Framework only checks if dependencies exist (curl, jq)
- Shows as ✓ (inline) in `./main.sh check`
- Runs immediately without installation

**Perfect for**:
- API queries (crt.sh, Censys, Shodan)
- Custom one-liners
- Shell script combinations
- Quick prototypes

---

### 3. Script Tools
**What**: Custom scripts or tools at specific file paths

**Examples**: custom Python/Bash scripts

**Config**:
```yaml
# config/general.yaml
tools:
  custom_script:
    enabled: true
    type: script  # Script at specific path
    command: "bash ~/tools/custom_script.sh {{INPUT}} {{OUTPUT}}"
    required_files: [urls.txt]
    outputs: [custom.txt]
```

```yaml
# config/install.yaml
tools:
  custom_script:
    install_method: git
    install_command: "git clone https://github.com/example/custom_script.git ~/tools/custom_script"
    binary_name: custom_script
    binary_path: "~/tools/custom_script/custom_script.sh"
```

**How it works**:
- Checks if script file exists and is executable
- Can specify custom path: `~/tools/custom_script/custom_script.sh`
- Shows as ✓ or ✗ based on file existence

---

## Adding Each Type

### Adding a Binary Tool

1. **Add to `config/install.yaml`**:
```yaml
tools:
  mytool:
    install_method: go  # or pip, apt
    install_command: "go install github.com/author/mytool@latest"
    binary_name: mytool
```

2. **Add to `config/general.yaml`**:
```yaml
tools:
  mytool:
    enabled: true
    type: binary
    command: "mytool -input {{INPUT}} -output {{OUTPUT}}"
    required_files: [urls.txt]
    outputs: [results.txt]
```

3. **Install**: `./main.sh update`

---

### Adding an Inline Command

1. **Add to `config/install.yaml`** (optional):
```yaml
tools:
  myapi:
    install_method: inline
    install_command: "# No installation needed"
    binary_name: myapi
    dependencies: [curl, jq]
```

2. **Add to `config/general.yaml`**:
```yaml
tools:
  myapi:
    enabled: true
    type: inline  # Key difference!
    command: "curl -s 'https://api.example.com/?domain={{DOMAIN}}' | jq -r '.[]'"
    required_files: []
    outputs: [api_results.txt]
```

3. **Done!** No installation needed.

---

### Adding a Script Tool

1. **Add to `config/install.yaml`**:
```yaml
tools:
  myscript:
    install_method: git  # or manual
    install_command: "git clone https://github.com/author/myscript.git ~/tools/myscript"
    binary_name: myscript
    binary_path: "~/tools/myscript/run.sh"
```

2. **Add to `config/general.yaml`**:
```yaml
tools:
  myscript:
    enabled: true
    type: script
    command: "bash ~/tools/myscript/run.sh {{INPUT}} {{OUTPUT}}"
    required_files: [urls.txt]
    outputs: [script_results.txt]
```

3. **Install**: `./main.sh update`

---

## Examples of Inline Commands

### Subdomain via API
```yaml
shodan_subs:
  enabled: true
  type: inline
  command: "curl -s 'https://api.shodan.io/dns/domain/{{DOMAIN}}?key=YOUR_API_KEY' | jq -r '.subdomains[]' | sed 's/$/{{DOMAIN}}/'"
  outputs: [wild.txt]
```

### GitHub Dorking
```yaml
github_dork:
  enabled: true
  type: inline
  command: "curl -s 'https://api.github.com/search/code?q={{DOMAIN}}+password' | jq -r '.items[].html_url'"
  outputs: [github_leaks.txt]
```

### Custom URL Filter
```yaml
filter_js:
  enabled: true
  type: inline
  command: "cat {{INPUT}} | grep -E '\\.js$' | sort -u"
  required_files: [urls.txt]
  outputs: [js_files.txt]
```

### Port Scanning
```yaml
nmap_quick:
  enabled: true
  type: inline
  command: "cat {{INPUT}} | while read host; do nmap -p 80,443,8080 $host --open -oG - ; done | grep '/open/'"
  required_files: [alive.txt]
  outputs: [ports.txt]
```

---

## Checking Tool Status

```bash
./main.sh check
```

Output:
```
[*] Checking tool installation status...

  [✓] subfinder              # Binary (installed)
  [✓] crt_sh (inline)        # Inline (always available)
  [✗] assetfinder            # Binary (not installed)
  [✓] httpx                  # Binary (installed)
  [!] myapi (inline - missing dependencies)  # Inline but curl missing

[*] Summary: 5 installed (2 inline), 2 missing
```

---

## Benefits

### Binary Tools
- ✅ Professional, maintained tools
- ✅ High performance
- ✅ Feature-rich
- ❌ Need installation

### Inline Commands
- ✅ **No installation needed**
- ✅ Quick to add/modify
- ✅ Perfect for APIs
- ✅ Easy to customize
- ❌ May be slower for large datasets

### Script Tools
- ✅ Custom logic
- ✅ Flexible
- ✅ Can be versioned
- ❌ Need to manage paths

---

## Tips

1. **Prototype with inline**, productionize with binary:
   ```yaml
   # Start with this
   type: inline
   command: "curl -s 'https://api.example.com/...'"

   # Later, create a proper tool and switch to
   type: binary
   command: "mytool {{DOMAIN}}"
   ```

2. **Combine types** in stages:
   ```yaml
   subdomain_enum:
     tools:
       - subfinder    # binary
       - crt_sh       # inline
       - amass        # binary
       - custom_api   # inline
   ```

3. **Use inline for one-offs**:
   - Quick API integrations
   - Data transformations
   - Filtering/grepping
   - Simple combinations

4. **Use binary for heavy lifting**:
   - Complex logic
   - Performance-critical tasks
   - Tools you use frequently

---

## Migration Guide

If you have existing custom commands:

**Before** (broken):
```yaml
tools:
  my_curl_command:
    enabled: true
    command: "curl -s 'https://api.example.com/...'"
```
❌ Framework tries to find `my_curl_command` binary (fails)

**After** (working):
```yaml
tools:
  my_curl_command:
    enabled: true
    type: inline  # Add this!
    command: "curl -s 'https://api.example.com/...'"
```
✅ Framework knows it's inline, doesn't check for binary

---

## Summary

| Type | Check Method | Installation | Use Case |
|------|-------------|--------------|----------|
| `binary` | `command -v` | Yes | Professional tools |
| `inline` | Dependencies only | No | APIs, one-liners |
| `script` | File exists | Manual/Git | Custom scripts |

Now your framework can handle **any** type of tool! 🎯
