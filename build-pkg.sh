#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Build a double-click .pkg that installs NoNoiseMac.app to /Applications AND the NoNoise Mic
# driver to the system HAL folder, then restarts coreaudiod so the virtual mic appears without a
# reboot. This is the no-Terminal install path for non-technical users (README → Install).
#
# Prereq: the app + driver bundles must already exist as siblings — run ./bundle.sh --with-driver.
# Output is UNSIGNED unless PKG_SIGN_IDENTITY (a "Developer ID Installer" identity) is set, so
# Developer-ID signing + notarization can be turned on later with no rework.

APP_BUNDLE="NoNoiseMac.app"
DRIVER_BUNDLE="NoNoiseMic.driver"
PKG_IDENTIFIER="com.ivalsaraj.NoNoiseMac.pkg"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

usage() {
    echo "Usage: ./build-pkg.sh [--version X.Y.Z] [--output PATH]"
    echo
    echo "Builds NoNoiseMac-<version>.pkg (app + virtual mic driver) from the already-built"
    echo "NoNoiseMac.app and NoNoiseMic.driver siblings. Run ./bundle.sh --with-driver first."
    echo
    echo "  --version X.Y.Z   Override the version (default: app CFBundleShortVersionString)."
    echo "  --output PATH     Output .pkg path (default: ./NoNoiseMac-<version>.pkg)."
    echo
    echo "Env: PKG_SIGN_IDENTITY  If set, productsign with this 'Developer ID Installer' identity."
}

VERSION=""
OUTPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --output)  OUTPUT="${2:?--output needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[ -d "$APP_BUNDLE" ]    || { echo "Missing $APP_BUNDLE — run ./bundle.sh --with-driver first." >&2; exit 1; }
[ -d "$DRIVER_BUNDLE" ] || { echo "Missing $DRIVER_BUNDLE — run ./bundle.sh --with-driver first." >&2; exit 1; }

if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
fi
[ -n "$VERSION" ] || { echo "Could not resolve version from $APP_BUNDLE." >&2; exit 1; }

[ -n "$OUTPUT" ] || OUTPUT="NoNoiseMac-${VERSION}.pkg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Payload root mirrors the final filesystem. ditto preserves the app's Sparkle.framework
# Versions/Current symlink + exec bits (cp -r would corrupt the framework — see bundle.sh).
ROOT="$WORK/root"
mkdir -p "$ROOT/Applications" "$ROOT$HAL_DIR"
ditto "$APP_BUNDLE" "$ROOT/Applications/$APP_BUNDLE"
ditto "$DRIVER_BUNDLE" "$ROOT$HAL_DIR/$DRIVER_BUNDLE"

# postinstall: load the just-installed driver by restarting coreaudiod (all audio drops for ~3s).
# Mirrors install-driver.sh's killall step — without it the new HAL plug-in only loads on reboot.
SCRIPTS="$WORK/scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# Restart coreaudiod so the just-installed NoNoise Mic driver is picked up without a reboot.
killall coreaudiod 2>/dev/null || true
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

# Component pkg. --ownership recommended assigns root:wheel to the system HAL location on install,
# regardless of the staging user. The payload is copied verbatim — the driver's ad-hoc signature
# is preserved (a post-sign edit would make coreaudiod silently drop the plug-in).
COMPONENT="$WORK/component.pkg"
pkgbuild \
    --root "$ROOT" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    --scripts "$SCRIPTS" \
    --install-location / \
    --ownership recommended \
    "$COMPONENT"

# Distribution wrapper: single-flow Installer UI (no customize), arm64-only, macOS 13+ guard.
DIST="$WORK/distribution.xml"
cat > "$DIST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>NoNoise Mac</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="13.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="NoNoise Mac">
        <pkg-ref id="$PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$PKG_IDENTIFIER" version="$VERSION">component.pkg</pkg-ref>
</installer-gui-script>
EOF

UNSIGNED="$WORK/unsigned.pkg"
productbuild --distribution "$DIST" --package-path "$WORK" "$UNSIGNED"

# Sign only when a Developer ID Installer identity is provided; otherwise ship unsigned.
if [ -n "${PKG_SIGN_IDENTITY:-}" ]; then
    echo "Signing with Developer ID Installer: $PKG_SIGN_IDENTITY"
    productsign --sign "$PKG_SIGN_IDENTITY" "$UNSIGNED" "$OUTPUT"
else
    echo "PKG_SIGN_IDENTITY not set → producing UNSIGNED .pkg (first run needs Open Anyway)."
    cp "$UNSIGNED" "$OUTPUT"
fi

echo "Built $OUTPUT (version $VERSION)"
