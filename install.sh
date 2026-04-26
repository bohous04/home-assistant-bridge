#!/bin/bash
set -euo pipefail

# macbook-ha-bridge installer
# Build, nainstaluje binary do ~/.local/bin a launchd agent do ~/Library/LaunchAgents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LOG_DIR="$HOME/Library/Logs"
CONFIG_DIR="$HOME/.config/macbook-ha-bridge"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="cz.lnrt.macbook-ha-bridge"
PLIST_PATH="$LAUNCH_DIR/$PLIST_LABEL.plist"

echo "==> Build"
mkdir -p "$BIN_DIR"
swiftc -O -o "$BIN_DIR/macbook-ha-bridge" "$SCRIPT_DIR/main.swift" \
    -framework Foundation -framework AppKit -framework IOKit -framework CoreGraphics

echo "==> Config"
mkdir -p "$CONFIG_DIR"
if [[ -f "$SCRIPT_DIR/config.json" ]]; then
    cp "$SCRIPT_DIR/config.json" "$CONFIG_DIR/config.json"
    echo "    Zkopírováno $SCRIPT_DIR/config.json → $CONFIG_DIR/config.json"
elif [[ ! -f "$CONFIG_DIR/config.json" ]]; then
    if [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
        cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
        echo "    Vytvořen $CONFIG_DIR/config.json z example — VYPLŇ token a haURL!"
        echo "    Pak pusť install.sh znovu."
        exit 0
    else
        echo "ERROR: chybí config.json i config.example.json v $SCRIPT_DIR" >&2
        exit 1
    fi
else
    echo "    Config už existuje v $CONFIG_DIR, nepřepisuju."
fi

echo "==> launchd plist"
mkdir -p "$LAUNCH_DIR" "$LOG_DIR"
sed \
    -e "s|HOME_BIN_PATH|$BIN_DIR|g" \
    -e "s|HOME_LOG_PATH|$LOG_DIR|g" \
    "$SCRIPT_DIR/cz.lnrt.macbook-ha-bridge.plist" > "$PLIST_PATH"

echo "==> Reload agent"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo "Hotovo. Logy: $LOG_DIR/macbook-ha-bridge.log"
echo "Restart agenta: launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
echo "Zastavit:      launchctl unload $PLIST_PATH"
