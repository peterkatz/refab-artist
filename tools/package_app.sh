#!/usr/bin/env bash
set -euo pipefail

# The release version and the build number written to Info.plist. The About
# panel shows them as "Version 0.1.0 (1)". Raise the build number for each
# binary built from the same version (REFAB_BUILD=2 tools/package_app.sh).
VERSION="${REFAB_VERSION:-0.1.0}"
BUILD="${REFAB_BUILD:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/app/RefabArtist"
# Where the app is written: build/ in this checkout, or REFAB_OUTPUT_DIR.
BUILD_DIR="${REFAB_OUTPUT_DIR:-$ROOT_DIR/build}"
APP_DIR="$BUILD_DIR/Refab Artist.app"
# The release build happens outside the checkout, in a directory whose path
# names nobody. SwiftPM compiles the absolute path of its build directory into
# the executable (the fallback location of the resource bundle), so a build
# inside a home directory would carry the builder's user name and checkout
# path into the app. Set REFAB_SCRATCH_PATH to use another neutral directory.
SCRATCH_DIR="${REFAB_SCRATCH_PATH:-/tmp/refab-artist-build}"
# RELEASE build: the app ships optimized. The debug binary is 5-10x slower
# on the geometry pipeline and was the bulk of "why is it so slow".
EXECUTABLE_SRC="$SCRATCH_DIR/arm64-apple-macosx/release/RefabArtist"
RESOURCE_BUNDLE_SRC="$SCRATCH_DIR/arm64-apple-macosx/release/RefabArtist_RefabArtist.bundle"

swift build -c release --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE_SRC" "$APP_DIR/Contents/MacOS/RefabArtist"
chmod +x "$APP_DIR/Contents/MacOS/RefabArtist"
# Drop the debug map: it names every object file and source directory of the
# build by absolute path. The executable in the build directory keeps it.
strip -S "$APP_DIR/Contents/MacOS/RefabArtist"
if [[ -d "$RESOURCE_BUNDLE_SRC" ]]; then
  cp -R "$RESOURCE_BUNDLE_SRC" "$APP_DIR/Contents/Resources/RefabArtist_RefabArtist.bundle"
fi
# Licence texts travel with the binary: GPL-3.0 for the app, plus the notices
# for statically linked third-party code (Manifold is Apache-2.0, §4(a);
# Clipper2 is Boost Software License 1.0).
cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PACKAGE_DIR/Vendor/Manifold/LICENSE-Manifold" "$APP_DIR/Contents/Resources/LICENSE-Manifold"
cp "$PACKAGE_DIR/Vendor/Manifold/LICENSE-Clipper2" "$APP_DIR/Contents/Resources/LICENSE-Clipper2"
# The app icon, drawn by tools/icon/make_app_icon.py (re-run it to change it).
cp "$PACKAGE_DIR/Packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>RefabArtist</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.refabartist.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Refab Artist</string>
  <key>CFBundleDisplayName</key>
  <string>Refab Artist</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (C) 2026 Pete Katz. Released under the GNU General Public License, version 3.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# The app must not carry a path or name of this machine.
"$ROOT_DIR/tools/check_app_paths.sh" "$APP_DIR"

echo "$APP_DIR"
