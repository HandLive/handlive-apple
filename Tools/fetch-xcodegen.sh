#!/bin/sh
# Unpacks the official XcodeGen release (MIT) into the directory given, after checking the zip's SHA-256 (the digest
# GitHub publishes for the release asset), and prints the path of its binary. CI and the release workflow generate
# HandLive.xcodeproj with it instead of Homebrew's current formula: the project of a tag is then made by a known
# generator, and a changed formula cannot reach a release build.
#   xcodegen="$(Tools/fetch-xcodegen.sh "$RUNNER_TEMP/xcodegen")" && "$xcodegen" generate
set -eu
VERSION=2.46.0
SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
DEST="${1:?usage: Tools/fetch-xcodegen.sh <directory>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl --fail --location --silent --show-error --retry 3 --max-time 300 --output "$WORK/xcodegen.zip" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/xcodegen.zip" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "xcodegen.zip checksum mismatch: $ACTUAL" >&2
    exit 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/xcodegen"
unzip -q "$WORK/xcodegen.zip" -d "$DEST"
echo "$DEST/xcodegen/bin/xcodegen"
