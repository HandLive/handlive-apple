#!/bin/sh
# Downloads the official SQLCipher Community Edition XCFramework that SQLCipher.swift 4.19.0 publishes (Zetetic,
# BSD-style license, see LICENSE.md), checks its SHA-256 (the checksum of SQLCipher.swift's own Package.swift) and
# unpacks it next to this script as SQLCipher.xcframework, which the local SQLCipher package links. The framework is
# not committed (.gitignore); run this once after cloning and again after a version bump. CI runs it before building:
# xcodebuild hangs while resolving the remote binary target on GitHub's macOS runners.
set -eu
VERSION=4.19.0
SHA256=39f02d2f04f0de2ba1facf215550bfc6e6e2c9971d5d8ebb0cdd604874781bd7
URL="https://github.com/sqlcipher/SQLCipher.swift/releases/download/$VERSION/SQLCipher.xcframework.zip"
DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$DIR/.fetched-version" # outside the framework: a file inside would break its code signature
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION $SHA256" ]; then
    echo "SQLCipher $VERSION already in place"
    exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl --fail --location --silent --show-error --retry 3 --max-time 300 --output "$WORK/SQLCipher.zip" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/SQLCipher.zip" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "SQLCipher.xcframework.zip checksum mismatch: $ACTUAL" >&2
    exit 1
fi
rm -rf "$DIR/SQLCipher.xcframework"
unzip -q "$WORK/SQLCipher.zip" -d "$WORK/unpacked"
mv "$WORK/unpacked/SQLCipher.xcframework" "$DIR/SQLCipher.xcframework"
echo "$VERSION $SHA256" > "$STAMP"
echo "SQLCipher $VERSION unpacked into $DIR/SQLCipher.xcframework"
