#!/bin/bash
APP_NAME="NoNoiseMac"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

# Optional: also build the NoNoise Mic virtual-mic driver (./bundle.sh --with-driver).
WITH_DRIVER=false
if [ "${1:-}" = "--with-driver" ]; then
    WITH_DRIVER=true
fi

# Clean
rm -rf "$APP_BUNDLE"

# Structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy Resources (CoreML Model, Icon, Logo)
# Note: CoreML compiles to .mlmodelc
cp -r "Resources/DeepFilterNet3_Streaming.mlmodelc" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || echo "Model not compiled? Skipping"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "Resources/NoNoiseMacLogo.png" "$APP_BUNDLE/Contents/Resources/"

# Build the driver BEFORE signing the app, and stage it as a SIBLING — never copy it inside the
# app bundle (a nested, separately-signed plug-in would invalidate the app's --deep signature).
if [ "$WITH_DRIVER" = true ]; then
    echo "Building NoNoise Mic driver (--with-driver)…"
    ./build-driver.sh
fi

# --- Embed Sparkle.framework. Use ditto (NOT cp -r) to preserve the Versions/Current symlink
#     and executable bits; cp -r would corrupt the framework and Sparkle would fail to load. ---
SPARKLE_FRAMEWORK="$(find .build -type d -name 'Sparkle.framework' -path '*artifacts*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK="$(find .build -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework not found under .build — run 'swift build -c release --arch arm64' first." >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Make the executable find the embedded framework via @rpath (idempotent).
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# --- Sign inside-out (deepest nested code first), ad-hoc. NEVER use --deep with Sparkle. ---
# Nested Sparkle code gets Hardened Runtime (-o runtime) per Sparkle's signing docs; the OUTER app
# stays ad-hoc with NO hardened runtime (preserves current behavior + the allow-jit entitlement).
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/Current"

for xpc in "$SPARKLE_VER"/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    case "$xpc" in
        *Downloader.xpc) codesign --force --sign - --options runtime --preserve-metadata=entitlements "$xpc" ;;
        *)               codesign --force --sign - --options runtime "$xpc" ;;
    esac
done
[ -e "$SPARKLE_VER/Autoupdate" ] && codesign --force --sign - --options runtime "$SPARKLE_VER/Autoupdate"
[ -e "$SPARKLE_VER/Updater.app" ] && codesign --force --sign - --options runtime "$SPARKLE_VER/Updater.app"
codesign --force --sign - --options runtime "$SPARKLE_FW"

# Finally the app itself: ad-hoc, with entitlements, NO hardened runtime.
codesign --force --sign - --entitlements "Resources/NoNoiseMac.entitlements" "$APP_BUNDLE"

# Verify the assembled, signed bundle (Sparkle nested code + app seal).
codesign --verify --deep --strict "$APP_BUNDLE"

# Export CLI
cp "$BUILD_DIR/NoNoiseMacCLI" .
echo "Exported CLI to ./NoNoiseMacCLI"

echo "Bundled and Signed $APP_BUNDLE"

if [ "$WITH_DRIVER" = true ]; then
    echo "Staged NoNoiseMic.driver next to $APP_BUNDLE. Install it with: sudo ./install-driver.sh"
fi
