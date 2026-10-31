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
    brew install --cask betoxf/tap/usagebar
    echo ""
    echo "  Done! Usagebar has been installed."
    echo ""
    echo "  To launch:  open -a Usagebar"
    echo "  To update:  brew upgrade --cask usagebar"
    echo "  To remove:  brew uninstall --cask usagebar"
    echo ""
else
    echo "  [!] Homebrew not found."
    echo ""
    echo "  Option 1: Install Homebrew first, then re-run this script:"
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
    echo "  Option 2: Download Usagebar.zip and move Usagebar.app to /Applications:"
    echo "    https://github.com/betoxf/Usagebar/releases/latest"
    echo ""
    exit 1
fi
