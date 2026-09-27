#!/usr/bin/env python3
"""Generate the Apple String Catalogs and Swift accessors from shared/strings/ui-strings.json (0.12.2).

Usage (from any directory):
    python3 apple/Packages/HLLocalization/Scripts/generate-strings.py          # write the files
    python3 apple/Packages/HLLocalization/Scripts/generate-strings.py --check  # exit 1 when a file drifts

Writes, relative to apple/:
    Packages/HLLocalization/Sources/HLLocalization/Resources/Localizable.xcstrings   (Xcode builds)
    Packages/HLLocalization/Sources/HLLocalization/CommandLineToolsResources/*.lproj (swift test without Xcode)
    Packages/HLLocalization/Sources/HLLocalization/Generated/L10n.swift              (type-safe accessors)
    macOS/HandLive/Resources/InfoPlist.xcstrings                                     (purpose strings, en + vi)
    macOS/Info.plist                                                                 (purpose strings, en; other keys kept)
    iOS/HandLive/Resources/InfoPlist.xcstrings                                       (purpose strings, en + vi)
    iOS/Info.plist                                                                   (purpose strings, en; other keys kept)
    iOS/HandLive/Resources/Localizable.xcstrings                                     (push.* loc-keys of APNs alerts)
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.dont_write_bytecode = True  # keep __pycache__ out of the repository

from strings_apple_resources import APP_INFO_PLIST, FALLBACK_DIR, IOS_INFO_PLIST, render_apple_resources  # noqa: E402
from strings_catalog import load_catalog  # noqa: E402
from strings_swift_accessors import render_swift_accessors  # noqa: E402

PACKAGE_DIR = SCRIPT_DIR.parent
WORKSPACE_ROOT = PACKAGE_DIR.parent.parent.parent
DEFAULT_CATALOG = WORKSPACE_ROOT / "shared/strings/ui-strings.json"
OWNED_DIRS = (FALLBACK_DIR, "Sources/HLLocalization/Generated")  # wholly owned: stray files are errors


def render_all(catalog: Path) -> dict[str, str]:
    entries = load_catalog(catalog)
    current = {}
    for name in (APP_INFO_PLIST, IOS_INFO_PLIST):
        plist = PACKAGE_DIR / name
        current[name] = plist.read_bytes() if plist.exists() else None
    resources = render_apple_resources(entries, current[APP_INFO_PLIST], current[IOS_INFO_PLIST])
    return {**resources, **render_swift_accessors(entries)}


def owned_files() -> set[str]:
    found = set()
    for owned in OWNED_DIRS:
        root = PACKAGE_DIR / owned
        if root.exists():
            found |= {str(p.relative_to(PACKAGE_DIR)) for p in root.rglob("*") if p.is_file()}
    return found


def check(expected: dict[str, str]) -> int:
    problems = []
    for relative, content in sorted(expected.items()):
        path = PACKAGE_DIR / relative
        if not path.exists():
            problems.append(f"missing: {relative}")
        elif path.read_text(encoding="utf-8") != content:
            problems.append(f"differs: {relative}")
    problems += [f"extra: {relative}" for relative in sorted(owned_files() - expected.keys())]
    if problems:
        print("Apple strings drift from ui-strings.json; run generate-strings.py:", file=sys.stderr)
        print("\n".join(f"  {line}" for line in problems), file=sys.stderr)
        return 1
    print(f"OK: {len(expected)} files match ui-strings.json")
    return 0


def write(expected: dict[str, str]) -> int:
    for owned in OWNED_DIRS:
        shutil.rmtree(PACKAGE_DIR / owned, ignore_errors=True)
    for relative, content in expected.items():
        path = PACKAGE_DIR / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    print(f"Wrote {len(expected)} files from the catalog")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="render in memory and compare with the files on disk")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG, help="path of ui-strings.json")
    args = parser.parse_args()
    expected = render_all(args.catalog)
    return check(expected) if args.check else write(expected)


if __name__ == "__main__":
    sys.exit(main())
