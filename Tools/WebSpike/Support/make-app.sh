#!/bin/sh
# Wraps the WebSpike binary in an app bundle so macOS asks for Automation on behalf of "Web Spike" itself instead of
# the terminal, the way the HandLive app will. Signs with hardened runtime and the Apple Events entitlement.
#   SIGN_IDENTITY="Developer ID Application: …" Support/make-app.sh    Developer ID (the W8 case)
#   Support/make-app.sh                                               ad-hoc signature (TCC forgets it on rebuild)
#   NO_ENTITLEMENT=1 Support/make-app.sh                              hardened runtime without the entitlement
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=.build/WebSpike.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/WebSpike "$app/Contents/MacOS/WebSpike"
cp Support/Info.plist "$app/Contents/Info.plist"
identity="${SIGN_IDENTITY:--}"
if [ "${NO_ENTITLEMENT:-0}" = 1 ]; then
    codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
else
    codesign --force --options runtime --timestamp=none --entitlements Support/WebSpike.entitlements \
        --sign "$identity" "$app"
fi
codesign --display --entitlements - --verbose=2 "$app" 2>&1 | grep -E "Authority|Signature|Identifier|runtime|apple-events" || true
echo "built $app"
