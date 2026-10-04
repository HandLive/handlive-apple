#!/usr/bin/env python3
"""Fails when a Swift file imports a module of this repository's packages that its target does not depend on.

CI tests the packages through shared schemes of HandLive.xcworkspace (Tools/make-test-scheme.sh): every module lands in
one products directory, so a target that imports a module outside its declared dependencies may still compile there,
depending on build order, while it fails when its package builds on its own. This check makes that deterministic: for
every target of Packages/*, each `import` of a module defined by Packages/* or ThirdParty/* must be in the closure of
the target's dependencies (Package.swift, read with `swift package dump-package`). System modules are not checked.

Usage, from anywhere: python3 Tools/check_package_imports.py
"""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMPORT = re.compile(
    r"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:(?:class|struct|enum|protocol|func|var|let|typealias)[ \t]+)?(\w+)",
    re.MULTILINE,
)


def load_packages():
    """identity (lower-cased directory name, as SwiftPM derives it for a path dependency) → (directory, manifest)."""
    packages = {}
    for manifest in sorted(ROOT.glob("Packages/*/Package.swift")) + sorted(ROOT.glob("ThirdParty/*/Package.swift")):
        directory = manifest.parent
        dumped = subprocess.run(["swift", "package", "dump-package", "--package-path", str(directory)],
                                check=True, capture_output=True, text=True).stdout
        packages[directory.name.lower()] = (directory, json.loads(dumped))
    return packages


def direct_dependencies(packages, identity, target_name):
    """(package identity, target name) of every module a target names in its dependencies."""
    _, manifest = packages[identity]
    target = next(t for t in manifest["targets"] if t["name"] == target_name)
    local_targets = {t["name"] for t in manifest["targets"]}
    dependency_identities = [kind[0]["identity"] for entry in manifest["dependencies"] for kind in entry.values()]
    for entry in target["dependencies"]:
        kind, value = next(iter(entry.items()))
        name = value[0]
        if kind == "target" or (kind == "byName" and name in local_targets):
            yield identity, name
            continue
        candidates = [value[1].lower()] if kind == "product" and value[1] else dependency_identities
        for other in candidates:
            for product in packages.get(other, (None, {"products": []}))[1]["products"]:
                if product["name"] == name:
                    yield from ((other, product_target) for product_target in product["targets"])


def closure(packages, identity, target_name, memo):
    """Module names a target may import: itself and everything its dependencies reach."""
    key = (identity, target_name)
    if key not in memo:
        memo[key] = {target_name}
        for dependency in direct_dependencies(packages, identity, target_name):
            memo[key] |= closure(packages, *dependency, memo)
    return memo[key]


def main():
    packages = load_packages()
    local_modules = {t["name"] for _, manifest in packages.values() for t in manifest["targets"]}
    memo, problems = {}, []
    for identity, (directory, manifest) in packages.items():
        if directory.parent.name != "Packages":
            continue  # third-party code is not ours to check
        for target in manifest["targets"]:
            default = "Tests" if target["type"] == "test" else "Sources"
            sources = directory / (target.get("path") or f"{default}/{target['name']}")
            allowed = closure(packages, identity, target["name"], memo)
            for file in sorted(sources.rglob("*.swift")):
                text = file.read_text(encoding="utf-8")
                for match in IMPORT.finditer(text):
                    module = match.group(1)
                    if module in local_modules and module not in allowed:
                        line = text.count("\n", 0, match.start()) + 1
                        problems.append((file.relative_to(ROOT), line, module, target["name"], directory.name))
    for file, line, module, target, package in problems:
        message = f"imports {module}, which target {target} does not depend on (Packages/{package}/Package.swift)"
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::error file=apple/{file},line={line}::{message}")
        print(f"{file}:{line}: {message}", file=sys.stderr)
    checked = sum(len(m["targets"]) for d, m in packages.values() if d.parent.name == "Packages")
    print(f"package imports: {checked} targets checked, {len(problems)} outside their dependencies")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
