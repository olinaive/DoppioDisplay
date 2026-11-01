#!/bin/zsh
# Builds DoppioDisplay.app into ./build.
# SIGN_IDENTITY: codesign identity. Defaults to "DoppioDisplay Local Signing" when present.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer the stable local identity (scripts/create-signing-identity.sh); ad-hoc ("-")
# makes macOS forget Screen Recording / Accessibility after every rebuild.
LOCAL_IDENTITY="DoppioDisplay Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
        echo "warning: signing ad-hoc; run scripts/create-signing-identity.sh to keep permissions across builds" >&2
    fi
fi
# Xcode's toolchain carries the SwiftUI macro plugins (@State and friends).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="build/DoppioDisplay.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DoppioDisplay "$APP/Contents/MacOS/DoppioDisplay"

# App icon: the Icon Composer package (macOS 26 glass layers), compiled by Xcode's actool
# into Assets.car plus a Doppio.icns fallback. Regenerate the package with
# design/tools/make-doppio-iconpackage.py.
xcrun actool Resources/Doppio.icon --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon Doppio \
    --output-partial-info-plist "$(mktemp -d)/partial.plist" --errors >/dev/null
# The doppio CLI ships inside the app; Settings › Automation links it into /usr/local/bin.
cp scripts/doppio "$APP/Contents/Resources/doppio"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.doppiodisplay</string>
    <key>CFBundleName</key><string>DoppioDisplay</string>
    <key>CFBundleDisplayName</key><string>DoppioDisplay</string>
    <key>CFBundleExecutable</key><string>DoppioDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.2</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>CFBundleIconFile</key><string>Doppio</string>
    <key>CFBundleIconName</key><string>Doppio</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>app.doppiodisplay</string>
            <key>CFBundleURLSchemes</key><array><string>doppio</string><string>vdisplay</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --identifier app.doppiodisplay "$APP"
echo "Built $APP"
