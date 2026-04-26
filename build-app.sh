#!/bin/bash
# Build macbook-ha-bridge.app + macbook-ha-bridge.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="macbook-ha-bridge"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_INFO="$APP_BUNDLE/Contents/Info.plist"
APP_PKGINFO="$APP_BUNDLE/Contents/PkgInfo"
APP_RES="$APP_BUNDLE/Contents/Resources"
DMG_OUT="$HOME/Downloads/$APP_NAME.dmg"
LOGO_SRC="$SCRIPT_DIR/logo.jpg"

echo "==> Clean"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_RES"

echo "==> Build universal binary (arm64 + x86_64)"
swiftc -O -target arm64-apple-macos11 \
    "$SCRIPT_DIR/main.swift" \
    -framework Foundation -framework AppKit -framework CoreGraphics \
    -o /tmp/mhb-arm64
swiftc -O -target x86_64-apple-macos11 \
    "$SCRIPT_DIR/main.swift" \
    -framework Foundation -framework AppKit -framework CoreGraphics \
    -o /tmp/mhb-x86
lipo -create /tmp/mhb-arm64 /tmp/mhb-x86 -output "$APP_BIN"
chmod +x "$APP_BIN"
echo "    archs: $(lipo -archs "$APP_BIN")"

echo "==> App icon (squircle-mask logo, build .icns)"
if [[ -f "$LOGO_SRC" ]]; then
    swiftc -O "$SCRIPT_DIR/mask-squircle.swift" -o /tmp/mhb-mask
    /tmp/mhb-mask "$LOGO_SRC" /tmp/logo-masked.png

    ICONSET=/tmp/AppIcon.iconset
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size /tmp/logo-masked.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) /tmp/logo-masked.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_RES/AppIcon.icns"
    cp /tmp/logo-masked.png "$APP_RES/AppIcon-1024.png"
    echo "    AppIcon.icns built ($(ls -la "$APP_RES/AppIcon.icns" | awk '{print $5}') bytes)"
else
    echo "    (no logo.jpg found, skipping icon)"
fi

echo "==> Info.plist"
HAS_ICON=$(test -f "$APP_RES/AppIcon.icns" && echo "yes" || echo "no")
cat > "$APP_INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>macbook-ha-bridge</string>
    <key>CFBundleIdentifier</key>
    <string>cz.lnrt.macbook-ha-bridge</string>
    <key>CFBundleName</key>
    <string>macbook-ha-bridge</string>
    <key>CFBundleDisplayName</key>
    <string>MacBook HA Bridge</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
$([ "$HAS_ICON" = "yes" ] && echo "    <key>CFBundleIconFile</key>
    <string>AppIcon</string>")
</dict>
</plist>
PLIST

echo "==> PkgInfo"
printf 'APPL????' > "$APP_PKGINFO"

echo "==> Strip xattrs"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "==> Ad-hoc codesign (placeholder, no Apple Developer ID)"
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | head -5

echo "==> Verify .app"
codesign -dv "$APP_BUNDLE" 2>&1 | head -5
echo ""

echo "==> Build DMG"
DMG_STAGE="/tmp/mhb-dmg-stage"
DMG_TMP="/tmp/mhb-tmp.dmg"
DMG_VOL="macbook-ha-bridge"
rm -rf "$DMG_STAGE" "$DMG_TMP"
mkdir -p "$DMG_STAGE/.background"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# README inside DMG
cat > "$DMG_STAGE/READ ME FIRST.txt" <<'README'
macbook-ha-bridge — instalace
=============================

1) Přetáhni "macbook-ha-bridge.app" doprava na "Applications".
2) V Applications dvojklikni na "macbook-ha-bridge".
3) Aplikace ukáže okno "Not installed" — klikni "Install…".
4) Zadej URL Home Assistantu, Long-Lived Access Token,
   Entity prefix a Device name.
5) Klikni "Save & Install" — daemon se spustí na pozadí.

Pokud při prvním spuštění uvidíš:
"macbook-ha-bridge cannot be opened because the developer
cannot be verified" — pravým klikem (Ctrl+klik) v Finderu
na .app → Open → znovu Open. Apple nevyžaduje
notarizaci u nepodepsaných apps, ale upozorní uživatele.

Aplikace neběží v doc liště pořád — okno otvírá GUI,
po zavření okna se app ukončí. Daemon ale dál běží
na pozadí (řízený launchd). Když chceš znova vidět
status, znova otevři aplikaci.
README

# Background image: prefer dmg_bg.png from project, else generate via Swift, else skip.
# DMG window content is 648×408 (1x) so a 1296×816 PNG renders at Retina 2x.
if [[ -f "$SCRIPT_DIR/dmg_bg.png" ]]; then
    cp "$SCRIPT_DIR/dmg_bg.png" "$DMG_STAGE/.background/background.png"
    echo "    using $SCRIPT_DIR/dmg_bg.png"
elif [[ -f "$SCRIPT_DIR/dmg_bg.jpg" ]]; then
    sips -s format png "$SCRIPT_DIR/dmg_bg.jpg" --out "$DMG_STAGE/.background/background.png" >/dev/null
    echo "    using $SCRIPT_DIR/dmg_bg.jpg (converted to png)"
elif [[ -f "$SCRIPT_DIR/make-dmg-bg.swift" ]]; then
    swiftc -O "$SCRIPT_DIR/make-dmg-bg.swift" -o /tmp/mhb-mkbg 2>/dev/null && \
        /tmp/mhb-mkbg "$DMG_STAGE/.background/background.png" || echo "    (background gen failed)"
fi

# Create writable DMG, mount, set Finder layout, then convert to compressed read-only.
# Window: 648×408 content area (matches 1296×816 background at 2x Retina).
hdiutil create -srcfolder "$DMG_STAGE" -volname "$DMG_VOL" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
    -format UDRW -size 50m -ov "$DMG_TMP" >/dev/null

DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" | grep -E '^/dev/disk[0-9]+s' | head -1 | awk '{print $1}')
sleep 2

osascript <<APPLESCRIPT 2>&1 | tail -5
tell application "Finder"
    tell disk "$DMG_VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 848, 630}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        try
            set background picture of theViewOptions to file ".background:background.png"
        end try
        set position of item "macbook-ha-bridge.app" of container window to {149, 212}
        set position of item "Applications" of container window to {492, 212}
        set position of item "READ ME FIRST.txt" of container window to {304, 318}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 2
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force

rm -f "$DMG_OUT"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
rm -f "$DMG_TMP"
rm -rf "$DMG_STAGE"
rm -f /tmp/mhb-arm64 /tmp/mhb-x86 /tmp/mhb-mask /tmp/mhb-mkbg /tmp/logo-masked.png /tmp/mhb-dmg-bg.png
rm -rf /tmp/AppIcon.iconset

echo ""
echo "==> Done"
ls -lh "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
ls -lh "$DMG_OUT"
