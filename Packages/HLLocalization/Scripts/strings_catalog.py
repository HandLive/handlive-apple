"""Read shared/strings/ui-strings.json and turn it into what the Apple generators need.

Only the standard library. The catalog is already checked by shared/tools/strings/check_strings.py; this module
re-checks what the Apple output depends on (placeholders, plural shape, identifiers) and fails loudly.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

LANGUAGES = ("en", "vi")
SOURCE_LANGUAGE = "en"
# Strings the shared Apple package carries: the Mac app and the iPhone/iPad app both use them.
APPLE_PLATFORMS = {"macos", "ios"}
# 0.12.2: {name} becomes %1$@ (string) or %1$lld (int), numbered in `args` order.
FORMAT_SPECIFIERS = {"string": "@", "int": "lld", "double": "f"}
SWIFT_TYPES = {"string": "String", "int": "Int", "double": "Double"}
PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]*)\}")

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
    "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
    "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws",
    "true", "try",
}


@dataclass(frozen=True)
class Argument:
    name: str
    type: str

    @property
    def swift_label(self) -> str:
        return lower_camel(self.name)

    @property
    def swift_type(self) -> str:
        return SWIFT_TYPES[self.type]


@dataclass(frozen=True)
class Entry:
    key: str
    texts: dict  # language → str, or language → {category: str} for plurals
    comment: str
    platforms: tuple
    args: tuple
    plist_key: str | None

    @property
    def is_plural(self) -> bool:
        return isinstance(self.texts[SOURCE_LANGUAGE], dict)

    @property
    def is_apple(self) -> bool:
        return bool(APPLE_PLATFORMS & set(self.platforms))

    def format_value(self, text: str) -> str:
        """Catalog text → Apple format string: `%` escaped when formatted, {name} → %N$spec."""
        if not self.args:
            return text
        positions = {arg.name: index + 1 for index, arg in enumerate(self.args)}
        types = {arg.name: arg.type for arg in self.args}

        def replace(match: re.Match) -> str:
            name = match.group(1)
            if name not in positions:
                raise ValueError(f"{self.key}: placeholder {{{name}}} is not declared in args")
            return f"%{positions[name]}${FORMAT_SPECIFIERS[types[name]]}"

        return PLACEHOLDER.sub(replace, text.replace("%", "%%"))


def load_catalog(path: Path) -> list[Entry]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("source_language") != SOURCE_LANGUAGE:
        raise ValueError("the catalog source language must be en")
    if tuple(document.get("languages", ())) != LANGUAGES:
        raise ValueError(f"the Apple generator knows the languages {LANGUAGES}, the catalog has {document.get('languages')}")
    entries = []
    for item in document["strings"]:
        args = tuple(Argument(arg["name"], arg["type"]) for arg in item.get("args", []))
        entry = Entry(
            key=item["key"], texts={lang: item[lang] for lang in LANGUAGES}, comment=item["comment"],
            platforms=tuple(item["platforms"]), args=args, plist_key=item.get("plist_key"),
        )
        _validate(entry)
        entries.append(entry)
    return entries


def _validate(entry: Entry) -> None:
    declared = {arg.name for arg in entry.args}
    for language in LANGUAGES:
        text = entry.texts[language]
        variants = text.values() if isinstance(text, dict) else [text]
        for variant in variants:
            used = set(PLACEHOLDER.findall(variant))
            if used != declared:
                raise ValueError(f"{entry.key} [{language}]: placeholders {sorted(used)} ≠ args {sorted(declared)}")
    if entry.is_plural and [(arg.name, arg.type) for arg in entry.args] != [("count", "int")]:
        raise ValueError(f"{entry.key}: a plural string takes exactly one int argument 'count'")


def swift_path(key: str) -> tuple[list[str], str]:
    """`status.connected_wifi` → (["Status"], "connectedWifi"); nested segments become nested enums."""
    segments = key.split(".")
    return [upper_camel(segment) for segment in segments[:-1]], member_name(segments[-1])


def upper_camel(segment: str) -> str:
    name = "".join(part[:1].upper() + part[1:] for part in segment.split("_"))
    return f"_{name}" if name[:1].isdigit() else name


def lower_camel(segment: str) -> str:
    head, *rest = segment.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def member_name(segment: str) -> str:
    name = lower_camel(segment)
    if name[:1].isdigit():
        return f"_{name}"
    return f"`{name}`" if name in SWIFT_KEYWORDS else name
