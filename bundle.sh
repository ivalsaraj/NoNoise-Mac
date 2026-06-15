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

# Sign with Entitlements (Crucial for Microphone Access)
codesign --force --deep --sign - --entitlements "Resources/NoNoiseMac.entitlements" "$APP_BUNDLE"

# Export CLI
cp "$BUILD_DIR/NoNoiseMacCLI" .
echo "Exported CLI to ./NoNoiseMacCLI"

echo "Bundled and Signed $APP_BUNDLE"

if [ "$WITH_DRIVER" = true ]; then
    echo "Staged NoNoiseMic.driver next to $APP_BUNDLE. Install it with: sudo ./install-driver.sh"
fi
