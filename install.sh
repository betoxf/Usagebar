#!/bin/bash
set -e

echo ""
echo "  Just A Usage Bar - Installer"
echo "  ============================="
echo ""

# Check for Homebrew
if command -v brew &>/dev/null; then
    echo "  [+] Homebrew found"
    echo "  [*] Installing via Homebrew..."
    brew install betoxf/tap/justausagebar
    echo ""
    echo "  Done! JustaUsageBar has been installed."
    echo ""
    echo "  To launch:  open -a JustaUsageBar"
    echo "  To update:  brew upgrade betoxf/tap/justausagebar"
    echo "  To remove:  brew uninstall justausagebar"
    echo ""
else
    echo "  [!] Homebrew not found."
    echo ""
    echo "  Option 1: Install Homebrew first, then re-run this script:"
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
    echo "  Option 2: Build from source:"
    echo "    git clone https://github.com/betoxf/JustaUsageBar.git"
    echo "    cd JustaUsageBar && make release"
    echo "    cp -R build/Release/JustaUsageBar.app /Applications/"
    echo ""
    exit 1
fi
