# Contributing to Claude Recon Framework

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in Issues
2. Use the bug report template
3. Include:
   - Your OS and version
   - Steps to reproduce
   - Expected vs actual behavior
   - Relevant logs (use -vv for verbose output)

### Suggesting Features

1. Check if the feature has been requested
2. Open a new issue with the feature request template
3. Describe:
   - Use case and motivation
   - Proposed solution
   - Alternative solutions considered

### Adding New Tools

Adding a new tool is easy! Follow these steps:

#### 1. Add to install.yaml

```yaml
tools:
  yourtool:
    install_method: go  # or pip, git, apt
    install_command: "go install github.com/author/yourtool@latest"
    update_check: "github:author/yourtool"
    binary_name: yourtool
```

#### 2. Add to general.yaml

```yaml
tools:
  yourtool:
    enabled: true
    command: "yourtool -input {{INPUT}} -output {{OUTPUT}}"
    required_files: [urls.txt]  # Input files needed
    outputs: [yourtool_results.txt]  # Output files
```

#### 3. Add to a Stage

```yaml
stages:
  your_stage:
    enabled: true
    parallel: false
    description: "Your stage description"
    tools:
      - existingtool
      - yourtool  # Add here
```

#### 4. Test

```bash
./main.sh check  # Verify tool detection
./main.sh update  # Install the tool
./main.sh recon --dry-run --full --url example.com  # Test
./main.sh recon --full --url example.com  # Run it
```

### Code Style

#### Bash

- Use `#!/usr/bin/env bash` shebang
- Set strict mode: `set -euo pipefail`
- Use meaningful variable names
- Comment complex logic
- Use functions for reusable code
- Quote variables: `"$variable"`
- Use `[[` instead of `[` for tests

Example:
```bash
# Good
check_file() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        return 0
    fi
    return 1
}

# Not ideal
check_file() {
    if [ -f $1 ]; then
        return 0
    fi
    return 1
}
```

#### YAML

- Use 2 spaces for indentation
- Use lowercase with underscores for keys
- Keep consistent ordering
- Add comments for clarity

### Testing

Before submitting a PR:

1. **Test tool installation**
   ```bash
   ./main.sh update
   ```

2. **Test dry-run mode**
   ```bash
   ./main.sh recon --dry-run --full --url example.com
   ```

3. **Test actual execution**
   ```bash
   ./main.sh recon --subs --url example.com
   ```

4. **Test TUI**
   ```bash
   ./main.sh enable_tools
   ./main.sh set_stages
   ```

5. **Test different verbosity levels**
   ```bash
   ./main.sh recon --url example.com  # Default
   ./main.sh recon --url example.com -v  # Verbose
   ./main.sh recon --url example.com -vv  # Very verbose
   ```

6. **Check for errors**
   ```bash
   shellcheck main.sh src/*.sh
   ```

### Pull Request Process

1. **Fork and Clone**
   ```bash
   git clone https://github.com/yourusername/claude-recon.git
   cd claude-recon
   git checkout -b feature/your-feature
   ```

2. **Make Changes**
   - Follow code style guidelines
   - Add/update tests
   - Update documentation

3. **Commit**
   ```bash
   git add .
   git commit -m "feat: add support for newtool"
   ```

   Commit message format:
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation
   - `style:` - Formatting
   - `refactor:` - Code restructuring
   - `test:` - Tests
   - `chore:` - Maintenance

4. **Push and PR**
   ```bash
   git push origin feature/your-feature
   ```
   Then open a PR on GitHub

5. **PR Review**
   - Address review comments
   - Keep PR focused and atomic
   - Update CHANGELOG.md

### Project Structure

```
claude-recon/
├── main.sh              # Entry point - handles CLI args
├── src/                 # Core modules
│   ├── logger.sh       # Logging with colors and verbosity
│   ├── config.sh       # YAML parsing and management
│   ├── tools.sh        # Tool execution logic
│   ├── stages.sh       # Stage orchestration
│   ├── output.sh       # File handling with anew
│   ├── updater.sh      # Installation and updates
│   └── tui.sh          # Interactive menus
├── config/             # Configuration files
│   ├── general.yaml    # Tools and stages
│   ├── profiles.yaml   # Scan profiles
│   └── install.yaml    # Installation info
├── README.md
├── CONTRIBUTING.md
└── CHANGELOG.md
```

### Module Responsibilities

- **main.sh**: Argument parsing, module loading, command dispatch
- **logger.sh**: All output and logging functions
- **config.sh**: YAML parsing, config loading, config updates
- **tools.sh**: Tool execution, parallel/sequential running
- **stages.sh**: Stage dependency checking, stage execution
- **output.sh**: File operations, anew integration, history
- **updater.sh**: Tool installation, updates, dependency checks
- **tui.sh**: Interactive menus for configuration

### Adding a New Module

If you need to add a new module:

1. Create `src/your_module.sh`
2. Source it in `main.sh`:
   ```bash
   source "$SCRIPT_DIR/src/your_module.sh"
   ```
3. Follow existing module patterns
4. Update this documentation

### Configuration Guidelines

#### Tool Commands

Use placeholder templates:
- `{{DOMAIN}}` - Target domain
- `{{URL}}` - Target URL
- `{{INPUT}}` - Input file path
- `{{OUTPUT}}` - Output file path
- `{{PROJECT_DIR}}` - Project directory

#### Dependencies

- `required_files`: Files that must exist before tool runs
- `depends_on`: Stages that must complete first
- `outputs`: Files the tool produces

### Common Issues

#### Tool not found after installation

**Problem**: Go tools installed but not in PATH

**Solution**:
```bash
export PATH=$PATH:$(go env GOPATH)/bin
echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
```

#### YAML parsing errors

**Problem**: Config file syntax error

**Solution**:
```bash
python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))"
```

#### Tool execution fails

**Problem**: Command placeholders not replaced

**Solution**: Check tool definition uses correct placeholders

## Questions?

- Open an issue with the "question" label
- Check existing issues and discussions
- Review the README and documentation

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Focus on what is best for the community
- Show empathy towards others

Thank you for contributing! 🎯
