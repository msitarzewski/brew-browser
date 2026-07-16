#!/bin/bash
# Build the SwiftUI executable with SPM, then wrap it in a .app bundle so it
# launches as a real, activatable Mac app (SPM alone produces a bare binary
# with no Info.plist, which macOS treats as a background process).
#
# Usage: native/build-app.sh [debug|release] [arm64|x86_64]   (default: debug, host arch)
#        The arch may also come from the ARCH env var; the positional arg wins.
#        No arch given = no --arch flag = exactly the historical host (arm64)
#        build. x86_64 native covers ONLY the four Intel Macs that run macOS 26
#        (MBP 16" 2019, MBP 13" 2020 4-port, iMac 27" 2020, Mac Pro 2019).
set -euo pipefail

CONFIG="${1:-debug}"
ARCH="${2:-${ARCH:-}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# With an explicit --arch, SwiftPM emits to .build/<arch>-apple-macosx/<config>/
# instead of .build/<config>/ — so BINDIR (which the binary copy, the resource-
# bundle glob, and the Sparkle.framework path below all hang off) MUST come from
# --show-bin-path with the same flags as the build itself.
if [ -n "$ARCH" ]; then
  echo "==> swift build ($CONFIG, $ARCH)"
  swift build -c "$CONFIG" --arch "$ARCH"
  BINDIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
else
  echo "==> swift build ($CONFIG)"
  swift build -c "$CONFIG"
  BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
BIN="$BINDIR/BrewBrowser"
APP="$HERE/BrewBrowser.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BrewBrowser"

# App icon — the real brew-browser icon (1024px .icns, shared with the Tauri
# app). Gives the .app a proper Dock/Finder/⌘-Tab icon instead of the generic
# placeholder. Referenced by CFBundleIconFile below.
if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SPM emits resource bundles (e.g. BrewBrowser_BrewBrowserKit.bundle) carrying
# categories.json / enrichment.json / AppIcon.icns. `Bundle.module` resolves
# them relative to the executable, searching Contents/Resources too — so we copy
# them into Resources/ (NOT MacOS/). Two reasons over the old MacOS/ placement:
#   1. Resources/ is the codesign-valid home for nested bundles; a bundle in
#      MacOS/ makes `codesign --deep` reject the app ("bundle format
#      unrecognized") because it expects a Mach-O there, not a directory.
#   2. SwiftPM resource bundles ship flat (no Info.plist), which codesign also
#      rejects — so we synthesize a minimal Info.plist in each, making the app
#      sign-clean for a future notarized release.
for b in "$BINDIR"/*.bundle; do
  [ -e "$b" ] || continue
  bname="$(basename "$b")"
  dest="$APP/Contents/Resources/$bname"
  cp -R "$b" "$dest"
  # Synthesize a minimal Info.plist ONLY when SwiftPM emitted a flat bundle
  # with no Info.plist anywhere. Newer toolchains (Xcode 27) emit a structured
  # bundle (Contents/Info.plist + Contents/Resources/…); adding a second
  # Info.plist at the bundle root there produces a hybrid that codesign
  # --deep --strict rejects ("unsealed contents present in the bundle root").
  # So skip synthesis when either a root OR a Contents/ Info.plist exists.
  if [ ! -f "$dest/Info.plist" ] && [ ! -f "$dest/Contents/Info.plist" ]; then
    # bundle id: strip .bundle, lowercase — e.g. com.zerologic.brew-browser-native.BrewBrowser_BrewBrowserKit
    bid="com.zerologic.brew-browser-native.${bname%.bundle}"
    cat > "$dest/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${bname%.bundle}</string>
    <key>CFBundleIdentifier</key><string>${bid}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
PLIST
  fi
done

# Sparkle.framework (Bundle C) — the self-updater. SPM emits it next to the
# binary; the binary links it as `@rpath/Sparkle.framework/...`. Bundle it under
# the standard Contents/Frameworks/ and add an @executable_path/../Frameworks
# rpath so the assembled .app resolves it at launch (the bare `swift build`
# binary already finds it via @loader_path next to itself in .build/).
SPARKLE_FW="$BINDIR/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  # -R preserves the framework's Versions symlink structure (codesign-required).
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
  # Add the Frameworks rpath if it isn't already present (install_name_tool errors
  # on a duplicate, so guard on the existing LC_RPATH list).
  if ! otool -l "$APP/Contents/MacOS/BrewBrowser" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/BrewBrowser"
  fi
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Brew Browser</string>
    <key>CFBundleDisplayName</key><string>Brew Browser</string>
    <key>CFBundleIdentifier</key><string>com.zerologic.brew-browser-native</string>
    <key>CFBundleExecutable</key><string>BrewBrowser</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.1</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Sparkle self-updater (Bundle C). Mirrors the Tauri updater: same PUBLIC
         host, new path. The feed URL is safe to commit; the private build host
         appears nowhere. -->
    <key>SUFeedURL</key><string>https://brew-browser.zerologic.com/appcast.xml</string>
    <!-- Sparkle ed25519 PUBLIC key (from `generate_keys`). Public by design —
         it ships in every app and only VERIFIES updates; the matching PRIVATE
         key lives in the maintainer's login Keychain and signs releases. Like
         the Tauri minisign pubkey in tauri.conf.json, it's safe to commit. -->
    <key>SUPublicEDKey</key><string>OoRc2WZfiHX21nhhm/inmv5l282Ob97GBwx+fZoML/E=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Ad-hoc re-sign LAST. Adding the Frameworks rpath with install_name_tool (above)
# invalidates the linker's ad-hoc signature on the main binary, and Apple Silicon
# refuses to launch a binary whose signature doesn't match — so the assembled app
# crashes immediately at launch unless we re-seal it. Sign inside-out (nested
# Sparkle code → framework → app) with the ad-hoc identity ("-") so the dev .app
# launches. A notarized release re-signs with a Developer ID after assembly.
echo "==> ad-hoc re-sign (install_name_tool invalidated the linker signature)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  # Sparkle ships nested code (XPC services, Updater.app, Autoupdate) that must be
  # signed before the framework that contains them.
  find "$FW" -type d \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --sign - --timestamp=none "{}" 2>/dev/null || true
  if [ -f "$FW/Versions/Current/Autoupdate" ]; then
    codesign --force --sign - --timestamp=none "$FW/Versions/Current/Autoupdate" 2>/dev/null || true
  fi
  codesign --force --sign - --timestamp=none "$FW" 2>/dev/null || true
fi
# Sign the resource bundles, then the app itself (outermost last).
for b in "$APP"/Contents/Resources/*.bundle; do
  [ -e "$b" ] || continue
  codesign --force --sign - --timestamp=none "$b" 2>/dev/null || true
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | tail -1 || true

echo "==> done: $APP"
echo "Launch with: open \"$APP\""
