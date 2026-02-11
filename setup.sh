#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC} ${YELLOW}Claude Recon Framework - Setup${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if script is executable
if [[ ! -x "main.sh" ]]; then
    echo -e "${YELLOW}[*]${NC} Making main.sh executable..."
    chmod +x main.sh
fi

# Check dependencies
echo -e "${BLUE}[*]${NC} Checking system dependencies..."

MISSING_DEPS=()

check_dep() {
    local dep="$1"
    if command -v "$dep" &> /dev/null; then
        echo -e "  ${GREEN}[✓]${NC} $dep"
    else
        echo -e "  ${RED}[✗]${NC} $dep (missing)"
        MISSING_DEPS+=("$dep")
    fi
}

check_dep "curl"
check_dep "jq"
check_dep "git"
check_dep "python3"
check_dep "pip3"
check_dep "go"

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}[!]${NC} Missing dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "To install on Ubuntu/Debian:"
    echo "  sudo apt update"
    echo "  sudo apt install -y curl jq git python3 python3-pip golang-go"
    echo ""
    exit 1
fi

# Check/install PyYAML
echo ""
echo -e "${BLUE}[*]${NC} Checking Python dependencies..."

if python3 -c "import yaml" 2>/dev/null; then
    echo -e "  ${GREEN}[✓]${NC} PyYAML"
else
    echo -e "  ${YELLOW}[*]${NC} Installing PyYAML..."
    pip3 install pyyaml
    echo -e "  ${GREEN}[✓]${NC} PyYAML installed"
fi

# Check Go PATH
echo ""
echo -e "${BLUE}[*]${NC} Checking Go environment..."

GOPATH=$(go env GOPATH)
GOBIN="$GOPATH/bin"

if [[ ":$PATH:" != *":$GOBIN:"* ]]; then
    echo -e "  ${YELLOW}[!]${NC} Go bin directory not in PATH"
    echo ""
    echo "Add this to your ~/.bashrc or ~/.zshrc:"
    echo "  export PATH=\$PATH:\$(go env GOPATH)/bin"
    echo ""
    echo "Then run: source ~/.bashrc"
    echo ""
else
    echo -e "  ${GREEN}[✓]${NC} Go PATH configured"
fi

# Test config loading
echo ""
echo -e "${BLUE}[*]${NC} Testing configuration..."

if python3 -c "import yaml; yaml.safe_load(open('config/general.yaml'))" 2>/dev/null; then
    echo -e "  ${GREEN}[✓]${NC} general.yaml"
else
    echo -e "  ${RED}[✗]${NC} general.yaml (syntax error)"
    exit 1
fi

if python3 -c "import yaml; yaml.safe_load(open('config/profiles.yaml'))" 2>/dev/null; then
    echo -e "  ${GREEN}[✓]${NC} profiles.yaml"
else
    echo -e "  ${RED}[✗]${NC} profiles.yaml (syntax error)"
    exit 1
fi

if python3 -c "import yaml; yaml.safe_load(open('config/install.yaml'))" 2>/dev/null; then
    echo -e "  ${GREEN}[✓]${NC} install.yaml"
else
    echo -e "  ${RED}[✗]${NC} install.yaml (syntax error)"
    exit 1
fi

echo ""
echo -e "${GREEN}[✓]${NC} Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Check tool installation status:"
echo "     ./main.sh check"
echo ""
echo "  2. Install tools:"
echo "     ./main.sh update"
echo ""
echo "  3. Run a test scan:"
echo "     ./main.sh recon --url example.com"
echo ""
echo "  4. Configure tools:"
echo "     ./main.sh enable_tools"
echo ""
echo "For more information, see README.md"
echo ""
