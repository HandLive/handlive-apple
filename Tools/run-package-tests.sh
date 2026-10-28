#!/bin/zsh
# Runs `swift test` for one Swift package under Packages/, logging everything (stdout+stderr) to
# handlive-apple/.build-logs/<package>-test.log so a long failure list survives a truncated terminal/ProTeam log
# (task #196 — 13 test failures got cut to the visible tail twice in a row when run straight). Prints the log's
# last 40 lines, then exits with swift test's own exit code.
#
# Usage: Tools/run-package-tests.sh <package>   (package name under Packages/, e.g. HLTransport)
set -uo pipefail
cd "$(dirname "$0")/.."

PACKAGE="${1:?package name under Packages/, e.g. HLTransport}"
[[ -d "Packages/$PACKAGE" ]] || { echo "no such package: Packages/$PACKAGE" >&2; exit 2; }

LOG_DIR=.build-logs
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$PACKAGE-test.log"

echo "Running: swift test --package-path Packages/$PACKAGE"
swift test --package-path "Packages/$PACKAGE" > "$LOG_FILE" 2>&1
EXIT_CODE=$?

echo "== last 40 lines of $LOG_FILE =="
tail -n 40 "$LOG_FILE"
echo "swift test exit code: $EXIT_CODE (full log: $LOG_FILE)"
exit "$EXIT_CODE"
