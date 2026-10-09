#!/bin/sh
# Writes a shared scheme into HandLive.xcworkspace that runs package test targets in ONE xcodebuild invocation, so the
# packages they share (HLProtocol, HLCrypto, GRDB, …) build once instead of once per package. CI runs one such scheme
# per shard in parallel jobs; locally `Tools/make-test-scheme.sh HLTests-all all` then
# `xcodebuild test -workspace HandLive.xcworkspace -scheme HLTests-all -destination 'platform=macOS'` tests everything.
#
# Usage: Tools/make-test-scheme.sh <scheme> all
#        Tools/make-test-scheme.sh <scheme> only <TestTarget>...
#        Tools/make-test-scheme.sh <scheme> except <TestTarget>...
#
# Test targets are read from Packages/*/Package.swift (`swift package dump-package`), so a new package or test target
# lands in an `all` or `except` scheme by itself. `only` fails on a name that is not a test target. Generated schemes
# are git-ignored (HLTests-*). Needs jq (built into macOS 15+; `brew install jq` before).
set -eu
cd "$(dirname "$0")/.."

scheme="${1:?scheme name}"
mode="${2:?all, only or except}"
shift 2
case "$scheme" in HLTests-*) ;; *) echo "scheme name must start with HLTests- (git-ignored)" >&2; exit 2 ;; esac
case "$mode" in all|only|except) ;; *) echo "mode must be all, only or except" >&2; exit 2 ;; esac

# "<package> <test target>" for every test target of every package. dump-package runs on its own, not in a pipe, so
# its failure stops the script (set -e) instead of silently dropping that package's tests.
available="$(for manifest in Packages/*/Package.swift; do
    package="$(basename "$(dirname "$manifest")")"
    json="$(swift package dump-package --package-path "Packages/$package")"
    printf '%s\n' "$json" | jq -r --arg p "$package" '.targets[] | select(.type == "test") | "\($p) \(.name)"'
done)"
[ -n "$available" ] || { echo "no test target found under Packages/" >&2; exit 2; }

for name in "$@"; do
    echo "$available" | awk -v t="$name" '$2 == t { found = 1 } END { exit !found }' \
        || { echo "not a test target of Packages/*: $name" >&2; exit 2; }
done

# `if` below, not `case`: macOS /bin/sh (bash 3.2) closes a command substitution at a case pattern parenthesis.
selected="$(echo "$available" | while read -r package target; do
    [ -n "$target" ] || continue
    listed=no
    for name in "$@"; do [ "$name" = "$target" ] && listed=yes; done
    if [ "$mode" = all ] || [ "$mode/$listed" = only/yes ] || [ "$mode/$listed" = except/no ]; then
        echo "$package $target"
    fi
done)"
[ -n "$selected" ] || { echo "no test target selected" >&2; exit 2; }

directory=HandLive.xcworkspace/xcshareddata/xcschemes
mkdir -p "$directory"
{
    cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = ""
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
HEAD
    echo "$selected" | while read -r package target; do
        [ -n "$target" ] || continue
        cat <<TESTABLE
         <TestableReference skipped = "NO" parallelizable = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "$target"
               BuildableName = "$target" BlueprintName = "$target" ReferencedContainer = "container:Packages/$package">
            </BuildableReference>
         </TestableReference>
TESTABLE
    done
    cat <<'TAIL'
      </Testables>
   </TestAction>
</Scheme>
TAIL
} > "$directory/$scheme.xcscheme"
echo "$scheme: $(echo "$selected" | awk '{ print $2 }' | tr '\n' ' ')"
