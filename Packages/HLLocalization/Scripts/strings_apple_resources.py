"""String Catalogs (.xcstrings), the Command Line Tools fallback (.lproj) and the app's Info.plist texts."""
from __future__ import annotations

import json
import plistlib

from strings_catalog import LANGUAGES, SOURCE_LANGUAGE, Entry

LOCALIZABLE_XCSTRINGS = "Sources/HLLocalization/Resources/Localizable.xcstrings"
# Xcode compiles .xcstrings; Command Line Tools cannot (no xcstringstool), so `swift test` there reads the same
# strings from .lproj files the generator writes next to it. Package.swift picks one of the two.
FALLBACK_DIR = "Sources/HLLocalization/CommandLineToolsResources"
TABLE = "Localizable"
# The Mac app target (paths relative to this package).
APP_INFOPLIST_XCSTRINGS = "../../macOS/HandLive/Resources/InfoPlist.xcstrings"
APP_INFO_PLIST = "../../macOS/Info.plist"
APP_PLATFORM = "macos"
# The iPhone and iPad app target: its purpose strings, and the `push.*` loc-keys APNs alerts name (CONN-04 API 4),
# which iOS looks up in the app's own Localizable table even when the Notification Service Extension changes nothing.
IOS_INFOPLIST_XCSTRINGS = "../../iOS/HandLive/Resources/InfoPlist.xcstrings"
IOS_INFO_PLIST = "../../iOS/Info.plist"
IOS_LOCALIZABLE_XCSTRINGS = "../../iOS/HandLive/Resources/Localizable.xcstrings"
IOS_PLATFORM = "ios"
PUSH_PREFIX = "push."


def _dump_xcstrings(strings: dict) -> str:
    document = {"sourceLanguage": SOURCE_LANGUAGE, "strings": strings, "version": "1.0"}
    # Same layout as Xcode writes, so opening the catalog in Xcode leaves no diff.
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")) + "\n"


def _string_unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def _localization(entry: Entry, language: str) -> dict:
    text = entry.texts[language]
    if isinstance(text, dict):
        variants = {category: _string_unit(entry.format_value(value)) for category, value in sorted(text.items())}
        return {"variations": {"plural": variants}}
    return _string_unit(entry.format_value(text))


def render_localizable_xcstrings(entries: list[Entry]) -> str:
    strings = {}
    for entry in entries:
        strings[entry.key] = {
            "comment": entry.comment,
            "extractionState": "manual",
            "localizations": {language: _localization(entry, language) for language in LANGUAGES},
        }
    return _dump_xcstrings(strings)


def render_infoplist_xcstrings(entries: list[Entry]) -> str:
    strings = {}
    for entry in entries:
        strings[entry.plist_key] = {
            "comment": entry.comment,
            "extractionState": "manual",
            "localizations": {language: _string_unit(entry.texts[language]) for language in LANGUAGES},
        }
    return _dump_xcstrings(strings)


def _plist(document: dict) -> str:
    return plistlib.dumps(document, sort_keys=True).decode("utf-8")


def render_fallback(entries: list[Entry]) -> dict[str, str]:
    """`<lang>.lproj/Localizable.strings` and `.stringsdict` (XML plists), what Xcode compiles .xcstrings into."""
    files = {}
    for language in LANGUAGES:
        strings, plurals = {}, {}
        for entry in entries:
            text = entry.texts[language]
            if isinstance(text, dict):
                rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"}
                rule.update({category: entry.format_value(value) for category, value in text.items()})
                plurals[entry.key] = {"NSStringLocalizedFormatKey": "%#@count@", "count": rule}
            else:
                strings[entry.key] = entry.format_value(text)
        files[f"{FALLBACK_DIR}/{language}.lproj/{TABLE}.strings"] = _plist(strings)
        files[f"{FALLBACK_DIR}/{language}.lproj/{TABLE}.stringsdict"] = _plist(plurals)
    return files


def render_info_plist(entries: list[Entry], current: bytes | None) -> str:
    """The app's Info.plist with every purpose string set to the catalog's English text; other keys kept."""
    document = plistlib.loads(current) if current else {}
    for entry in entries:
        document[entry.plist_key] = entry.texts[SOURCE_LANGUAGE]
    return _plist(document)


def render_apple_resources(entries: list[Entry], info_plist: bytes | None,
                           ios_info_plist: bytes | None = None) -> dict[str, str]:
    apple = [entry for entry in entries if entry.is_apple]
    app_plist = [entry for entry in entries if entry.plist_key and APP_PLATFORM in entry.platforms]
    ios_plist = [entry for entry in entries if entry.plist_key and IOS_PLATFORM in entry.platforms]
    push = [entry for entry in entries if entry.key.startswith(PUSH_PREFIX) and IOS_PLATFORM in entry.platforms]
    return {
        LOCALIZABLE_XCSTRINGS: render_localizable_xcstrings(apple),
        **render_fallback(apple),
        APP_INFOPLIST_XCSTRINGS: render_infoplist_xcstrings(app_plist),
        APP_INFO_PLIST: render_info_plist(app_plist, info_plist),
        IOS_INFOPLIST_XCSTRINGS: render_infoplist_xcstrings(ios_plist),
        IOS_INFO_PLIST: render_info_plist(ios_plist, ios_info_plist),
        IOS_LOCALIZABLE_XCSTRINGS: render_localizable_xcstrings(push),
    }
