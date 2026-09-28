#!/bin/bash
# Builds the camera spike (gate G5). Needs Xcode and XcodeGen. Installs nothing and changes no system setting:
# copying the app to /Applications, approving the extension and installing the PKG are the owner's steps (README.md).
#
#   ./build.sh test                  unit tests of CameraSpikeKit + load the HAL plug-in in-process and check it
#   ./build.sh unsigned              build everything without signing (compile check only; cannot be activated)
#   ./build.sh dev <TEAM_ID>         sign with the team's Apple Development certificate (automatic signing)
#   ./build.sh developer-id <TEAM_ID>  archive, export for Developer ID, notarize and staple (HL_NOTARY_PROFILE)
#   ./build.sh pkg                   build HandLiveSpikeMic.pkg and HandLiveSpikeMic-Uninstall.pkg from the last build
#
# Environment: HL_BUILD_NUMBER (default 1) sets CFBundleVersion of all three bundles — raise it to test an update of
# the extension (C11). HL_ALLOW_PROVISIONING=1 lets xcodebuild create/download profiles with the Xcode account.
# HL_INSTALLER_IDENTITY="Developer ID Installer: …" signs the PKGs. HL_NOTARY_PROFILE names a `notarytool
# store-credentials` keychain profile. Output: .build/products/.
set -euo pipefail

cd "$(dirname "$0")"
OUT=.build/products
DERIVED=.build/xcode
BUILD_NUMBER="${HL_BUILD_NUMBER:-1}"
mode="${1:-}"

generate() {
    xcodegen generate --quiet
}

xcb() {
    local extra=()
    [ "${HL_ALLOW_PROVISIONING:-0}" = 1 ] && extra+=(-allowProvisioningUpdates)
    xcodebuild -project CameraSpike.xcodeproj -derivedDataPath "$DERIVED" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${extra[@]+"${extra[@]}"} "$@"
}

collect() {
    local config="$1"
    rm -rf "$OUT/HandLiveCameraSpike.app" "$OUT/HandLiveSpikeMic.driver"
    mkdir -p "$OUT"
    cp -R "$DERIVED/Build/Products/$config/HandLiveCameraSpike.app" "$DERIVED/Build/Products/$config/HandLiveSpikeMic.driver" "$OUT/"
    echo "built (CFBundleVersion $BUILD_NUMBER):"
    ls -d "$OUT"/*.app "$OUT"/*.driver
}

build_all() {
    local config="$1"
    shift
    for scheme in CameraSpikeHost HandLiveSpikeMic; do
        xcb build -scheme "$scheme" -configuration "$config" -destination 'generic/platform=macOS' "$@"
    done
    collect "$config"
}

case "$mode" in
test)
    swift test
    generate
    xcb build -scheme HandLiveSpikeMic -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
    mkdir -p .build
    clang -Wall -Werror -framework CoreFoundation -framework CoreAudio -o .build/PluginSmokeTest Tests/PluginSmokeTest/PluginSmokeTest.c
    .build/PluginSmokeTest "$DERIVED/Build/Products/Debug/HandLiveSpikeMic.driver"
    ;;
unsigned)
    generate
    build_all Release CODE_SIGNING_ALLOWED=NO
    ;;
dev)
    team="${2:?usage: ./build.sh dev <TEAM_ID>}"
    generate
    build_all Release DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Apple Development"
    codesign --verify --deep --strict --verbose=2 "$OUT/HandLiveCameraSpike.app"
    codesign -d --entitlements - "$OUT/HandLiveCameraSpike.app"
    ;;
developer-id)
    team="${2:?usage: ./build.sh developer-id <TEAM_ID>}"
    : "${HL_NOTARY_PROFILE:?set HL_NOTARY_PROFILE to a notarytool keychain profile}"
    generate
    xcb archive -scheme CameraSpikeHost -configuration Release -destination 'generic/platform=macOS' \
        -archivePath .build/CameraSpikeHost.xcarchive DEVELOPMENT_TEAM="$team"
    xcb -exportArchive -archivePath .build/CameraSpikeHost.xcarchive -exportPath "$OUT" \
        -exportOptionsPlist Packaging/ExportOptions-DeveloperID.plist
    xcb build -scheme HandLiveSpikeMic -configuration Release -destination 'generic/platform=macOS' \
        DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual
    rm -rf "$OUT/HandLiveSpikeMic.driver"
    cp -R "$DERIVED/Build/Products/Release/HandLiveSpikeMic.driver" "$OUT/"
    ditto -c -k --keepParent "$OUT/HandLiveCameraSpike.app" .build/HandLiveCameraSpike.zip
    xcrun notarytool submit .build/HandLiveCameraSpike.zip --keychain-profile "$HL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT/HandLiveCameraSpike.app"
    echo "App notarized. Run ./build.sh pkg with HL_INSTALLER_IDENTITY set, then notarize the PKG (README)."
    ;;
pkg)
    driver="$OUT/HandLiveSpikeMic.driver"
    [ -d "$driver" ] || { echo "no $driver: run ./build.sh dev|unsigned|developer-id first" >&2; exit 1; }
    root=.build/pkgroot
    rm -rf "$root" && mkdir -p "$root/Library/Audio/Plug-Ins/HAL"
    # Without extended attributes where possible. macOS keeps com.apple.provenance on files this shell creates, and
    # pkgbuild lists it as "._" entries in the payload; Installer restores those as attributes, not as files.
    ditto --norsrc --noextattr --noacl "$driver" "$root/Library/Audio/Plug-Ins/HAL/HandLiveSpikeMic.driver"
    # Never relocate: Installer must write to /Library/Audio/Plug-Ins/HAL even if another copy exists elsewhere.
    pkgbuild --analyze --root "$root" .build/components.plist >/dev/null
    plutil -replace 0.BundleIsRelocatable -bool NO .build/components.plist
    sign=()
    [ -n "${HL_INSTALLER_IDENTITY:-}" ] && sign=(--sign "$HL_INSTALLER_IDENTITY")
    pkgbuild --root "$root" --component-plist .build/components.plist --install-location / \
        --identifier app.handlive.spike.mic --version "$BUILD_NUMBER" --scripts Packaging/scripts-install \
        ${sign[@]+"${sign[@]}"} "$OUT/HandLiveSpikeMic.pkg"
    pkgbuild --nopayload --identifier app.handlive.spike.mic.uninstall --version "$BUILD_NUMBER" \
        --scripts Packaging/scripts-uninstall ${sign[@]+"${sign[@]}"} "$OUT/HandLiveSpikeMic-Uninstall.pkg"
    pkgutil --payload-files "$OUT/HandLiveSpikeMic.pkg"
    ;;
*)
    sed -n '2,15p' "$0"
    exit 2
    ;;
esac
