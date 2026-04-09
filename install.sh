#!/bin/bash
set -e

echo ""
echo "  Usagebar - Installer"
echo "  ============================="
echo ""

# Check for Homebrew
if command -v brew &>/dev/null; then
    echo "  [+] Homebrew found"
    echo "  [*] Installing via Homebrew..."
    brew install betoxf/tap/usagebar
    echo ""
    echo "  Done! Usagebar has been installed."
    echo ""
    echo "  To launch:  open -a Usagebar"
    echo "  To update:  brew upgrade betoxf/tap/usagebar"
    echo "  To remove:  brew uninstall usagebar"
    echo ""
else
    echo "  [!] Homebrew not found."
    echo ""
    echo "  Option 1: Install Homebrew first, then re-run this script:"
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
    echo "  Option 2: Build from source:"
    echo "    git clone https://github.com/betoxf/Usagebar.git"
    echo "    cd Usagebar && make release"
    echo "    cp -R build/Release/Usagebar.app /Applications/"
    echo ""
    exit 1
fi
