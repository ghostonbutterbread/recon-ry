# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-02-10

### Added
- Initial release of Claude Recon Framework
- Modular bash-based architecture
- YAML-driven configuration system
- Interactive TUI for tool and stage management
- Support for profiles (full, subs, secrets, dork)
- Automatic tool installation and updates
- History tracking with timestamps
- Parallel and sequential tool execution
- Integration with anew for deduplication
- Dry-run mode for testing
- Verbosity levels (-v, -vv)
- Smart dependency checking
- Project directory and single URL modes

### Tools Integrated
- subfinder - Subdomain enumeration
- httpx - HTTP probing
- katana - Web crawling
- nuclei - Vulnerability scanning
- assetfinder - Asset discovery
- amass - Network mapping
- waybackurls - Wayback machine URLs
- gau - Get all URLs
- hakrawler - Web crawler
- uro - URL deduplication
- ffuf - Fuzzing
- trufflehog - Secret scanning
- anew - Unique line filtering

### Configuration Files
- general.yaml - Tools and stages
- profiles.yaml - Scan profiles
- install.yaml - Installation info

### Modules
- logger.sh - Logging system
- config.sh - Config management
- tools.sh - Tool execution
- stages.sh - Stage orchestration
- output.sh - File handling
- updater.sh - Tool updates
- tui.sh - Interactive menus

## [Unreleased]

### Planned Features
- Web-based dashboard for results
- Notification system (Slack, Discord, Email)
- Diff mode to compare scan results
- Export to JSON/CSV/HTML
- Docker container support
- CI/CD integration examples
- More tool integrations
- Advanced filtering options
- Rate limiting and resource control
