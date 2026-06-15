#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NoNoiseMac"
APP_BUNDLE="$APP_NAME.app"
APPLICATIONS_DIR="/Applications"
TARGET_APP="$APPLICATIONS_DIR/$APP_BUNDLE"
WITH_DRIVER=false

usage() {
    echo "Usage: ./install-app.sh [--with-driver]"
    echo
    echo "Builds an optimized arm64 release, bundles NoNoise Mac, and installs it to /Applications."
    echo "  --with-driver   Also build and stage NoNoiseMic.driver next to the app."
}

for arg in "$@"; do
    case "$arg" in
        --with-driver)
            WITH_DRIVER=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ "$(uname -m)" != "arm64" ]; then
    echo "NoNoise Mac is Apple-Silicon-only; build/install must run on arm64." >&2
    exit 1
fi

echo "Building optimized arm64 release..."
swift build -c release --arch arm64

echo "Bundling app..."
if [ "$WITH_DRIVER" = true ]; then
    ./bundle.sh --with-driver
else
    ./bundle.sh
fi

if [ ! -w "$APPLICATIONS_DIR" ] || { [ -e "$TARGET_APP" ] && [ ! -w "$TARGET_APP" ]; }; then
    NEEDS_SUDO=true
else
    NEEDS_SUDO=false
fi

echo "Installing $APP_BUNDLE to $APPLICATIONS_DIR..."
if [ "$NEEDS_SUDO" = true ]; then
    sudo rm -rf "$TARGET_APP"
    sudo ditto "$APP_BUNDLE" "$TARGET_APP"
else
    rm -rf "$TARGET_APP"
    ditto "$APP_BUNDLE" "$TARGET_APP"
fi

codesign --verify --deep --strict "$TARGET_APP"

echo "Installed $TARGET_APP"
echo "First launch may require right-click → Open because the app is ad-hoc signed."

if [ "$WITH_DRIVER" = true ]; then
    echo "NoNoiseMic.driver was staged next to $APP_BUNDLE. Install it with: sudo ./install-driver.sh"
fi
