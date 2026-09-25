"""Đọc shared/design-tokens/tokens.json và chuẩn hóa thành dữ liệu cho bộ sinh Apple.

Chỉ dùng thư viện chuẩn. Mọi quy tắc suy diễn (bí danh màu, text style, tên PostScript)
nằm ở đây để bộ sinh asset catalog và bộ sinh Swift dùng chung một nguồn.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

# Thứ tự 4 giao diện; khớp `color.themes` trong tokens.json.
THEMES = ("light", "dark", "light-hc", "dark-hc")

@dataclass(frozen=True)
class SystemColorAPI:
    """Biểu thức Swift gọi màu của hệ thống cho một token (01-mau-sac.md, bảng "Màu ngữ nghĩa và API").

    `appkit`/`uikit` = None: nền tảng đó không có API → dùng giá trị hex của token.
    `appkit_min`: phiên bản macOS tối thiểu của API AppKit; trước đó dùng hex (macOS 13).
    """

    appkit: str | None
    uikit: str | None
    appkit_min: str | None = None


def _both(expression: str) -> SystemColorAPI:
    return SystemColorAPI(expression, expression)


def _ns(name: str) -> str:
    return f"Color(nsColor: .{name})"


def _ui(name: str) -> str:
    return f"Color(uiColor: .{name})"


# Token (hoặc bí danh trỏ tới token) có trong bảng này gọi API hệ thống thay vì hex
# (01-mau-sac.md: "Không hard-code màu hệ thống trên Apple"). Màu SwiftUI dùng chung hai nền tảng.
SYSTEM_COLORS = {
    "system-red": _both("Color.red"),
    "system-orange": _both("Color.orange"),
    "system-yellow": _both("Color.yellow"),
    "system-green": _both("Color.green"),
    "system-pink": _both("Color.pink"),
    "system-purple": _both("Color.purple"),
    "system-brown": _both("Color.brown"),
    "system-gray": _both("Color.gray"),
    # AppKit chỉ có systemGray; Gray 2–6 là của iOS (01-mau-sac.md).
    "system-gray-2": SystemColorAPI(None, _ui("systemGray2")),
    "system-gray-3": SystemColorAPI(None, _ui("systemGray3")),
    "system-gray-4": SystemColorAPI(None, _ui("systemGray4")),
    "system-gray-5": SystemColorAPI(None, _ui("systemGray5")),
    "system-gray-6": SystemColorAPI(None, _ui("systemGray6")),
    "label": _both("Color.primary"),
    "secondary-label": _both("Color.secondary"),
    "tertiary-label": SystemColorAPI(_ns("tertiaryLabelColor"), _ui("tertiaryLabel")),
    "quaternary-label": SystemColorAPI(_ns("quaternaryLabelColor"), _ui("quaternaryLabel")),
    "placeholder-text": SystemColorAPI(_ns("placeholderTextColor"), _ui("placeholderText")),
    "link": _both("Color.accentColor"),
    "separator": SystemColorAPI(_ns("separatorColor"), _ui("separator")),
    "opaque-separator": SystemColorAPI(None, _ui("opaqueSeparator")),
    "system-background": SystemColorAPI(None, _ui("systemBackground")),
    "secondary-system-background": SystemColorAPI(None, _ui("secondarySystemBackground")),
    "tertiary-system-background": SystemColorAPI(None, _ui("tertiarySystemBackground")),
    "system-grouped-background": SystemColorAPI(None, _ui("systemGroupedBackground")),
    "secondary-system-grouped-background": SystemColorAPI(None, _ui("secondarySystemGroupedBackground")),
    "tertiary-system-grouped-background": SystemColorAPI(None, _ui("tertiarySystemGroupedBackground")),
    "window-background": SystemColorAPI(_ns("windowBackgroundColor"), None),
    "control-background": SystemColorAPI(_ns("controlBackgroundColor"), None),
    # NSColor.systemFill… có từ macOS 14; macOS 13 dùng hex của token.
    "system-fill": SystemColorAPI(_ns("systemFill"), _ui("systemFill"), "14"),
    "secondary-system-fill": SystemColorAPI(_ns("secondarySystemFill"), _ui("secondarySystemFill"), "14"),
    "tertiary-system-fill": SystemColorAPI(_ns("tertiarySystemFill"), _ui("tertiarySystemFill"), "14"),
    "quaternary-system-fill": SystemColorAPI(_ns("quaternarySystemFill"), _ui("quaternarySystemFill"), "14"),
}

# Đuôi tên token mac-*/ios-* → Font.TextStyle (03-kieu-chu.md, bảng macOS và iOS).
SUFFIX_TEXT_STYLES = {
    "large-title": "largeTitle", "title-1": "title", "title-2": "title2", "title-3": "title3",
    "headline": "headline", "body": "body", "callout": "callout", "subheadline": "subheadline",
    "footnote": "footnote", "caption-1": "caption", "caption-2": "caption2",
}
# Be Vietnam Pro theo weight. 800 chỉ dùng khi người dùng bật Chữ đậm (tăng một bậc từ 700, 03-kieu-chu.md).
BRAND_POSTSCRIPT_NAMES = {600: "BeVietnamPro-SemiBold", 700: "BeVietnamPro-Bold", 800: "BeVietnamPro-ExtraBold"}
APPLE_TYPE_PREFIXES = ("brand-", "mac-", "ios-")
APPLE_TYPE_EXTRA = {"wordmark", "code-pin", "timer"}


@dataclass(frozen=True)
class RGBA:
    red: int
    green: int
    blue: int
    alpha: int  # 0…255

    @staticmethod
    def parse(hex_value: str) -> "RGBA":
        match = re.fullmatch(r"#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?", hex_value)
        if not match:
            raise ValueError(f"Màu không hợp lệ: {hex_value}")
        rgb, alpha = match.group(1), match.group(2) or "ff"
        return RGBA(int(rgb[0:2], 16), int(rgb[2:4], 16), int(rgb[4:6], 16), int(alpha, 16))


@dataclass(frozen=True)
class ColorToken:
    name: str
    usage: str
    values: dict  # theme → RGBA
    system: SystemColorAPI | None  # API hệ thống nếu token là màu hệ thống


@dataclass(frozen=True)
class TextStyleToken:
    name: str
    family: str  # brand | system | mono
    size: float
    line_height: float
    weight: int
    letter_spacing_em: float
    text_style: str
    postscript_name: str | None
    monospaced_digit: bool
    usage: str
    emphasis_weight: int
    # Tên PostScript khi bật Chữ đậm (weight tăng một bậc); chỉ họ brand.
    bold_text_postscript_name: str | None


@dataclass(frozen=True)
class MetricToken:
    name: str
    value: float
    usage: str


def _alias(value):
    match = re.fullmatch(r"\{([a-z0-9-]+)\}", value) if isinstance(value, str) else None
    return match.group(1) if match else None


def _resolve_color(name: str, raw: dict, seen: tuple = ()) -> tuple[dict, SystemColorAPI | None]:
    """Trả về (theme → RGBA, API hệ thống) sau khi lần theo chuỗi bí danh."""
    if name in seen:
        raise ValueError(f"Bí danh màu vòng lặp: {' → '.join(seen + (name,))}")
    system = SYSTEM_COLORS.get(name)
    value = raw[name]
    target = _alias(value)
    if target:
        values, target_system = _resolve_color(target, raw, seen + (name,))
        return values, system or target_system
    if isinstance(value, str):
        return {theme: RGBA.parse(value) for theme in THEMES}, system
    return {theme: RGBA.parse(value[theme]) for theme in THEMES}, system


def load_colors(tokens: dict) -> list[ColorToken]:
    themes = tuple(theme["id"] for theme in tokens["color"]["themes"])
    if themes != THEMES:
        raise ValueError(f"tokens.json đổi bộ giao diện: {themes}")
    raw = {item["name"]: item["value"] for item in tokens["color"]["tokens"]}
    result = []
    for item in tokens["color"]["tokens"]:
        values, system = _resolve_color(item["name"], raw)
        result.append(ColorToken(item["name"], item["usage"], values, system))
    return result


def _px(value: str) -> float:
    return float(value.removesuffix("px"))


def _is_apple_style(name: str) -> bool:
    return name.startswith(APPLE_TYPE_PREFIXES) or name in APPLE_TYPE_EXTRA


def load_text_styles(tokens: dict, extras: dict) -> list[TextStyleToken]:
    """Kiểu chữ Apple; `relativeTo`, `emphasisWeight`, `fontFeatures` đọc từ type-extras.json."""
    extra_styles = extras["styles"]
    result = []
    for group in tokens["type"]["groups"]:
        for style in group["styles"]:
            name = style["name"]
            if not _is_apple_style(name):
                continue
            extra = extra_styles.get(name)
            if extra is None:
                raise ValueError(f"type-extras.json thiếu kiểu chữ {name}")
            suffix = name.split("-", 1)[1] if name.startswith(("mac-", "ios-")) else None
            # macOS không có Dynamic Type nên mac-* không ghi relativeTo; lấy text style theo đuôi tên.
            text_style = extra.get("relativeTo") or SUFFIX_TEXT_STYLES[suffix]
            weight = int(style["fontWeight"])
            family = style["family"]
            postscript = BRAND_POSTSCRIPT_NAMES[weight] if family == "brand" else None
            bold_text = BRAND_POSTSCRIPT_NAMES[min(weight + 100, 800)] if family == "brand" else None
            result.append(TextStyleToken(
                name, family, _px(style["fontSize"]), _px(style["lineHeight"]), weight,
                float(style["letterSpacing"].removesuffix("em")), text_style, postscript,
                "tnum" in extra.get("fontFeatures", []), style["usage"],
                int(extra["emphasisWeight"]), bold_text,
            ))
    return result


def load_metrics(tokens: dict, family: str) -> list[MetricToken]:
    result = []
    for item in tokens[family]["tokens"]:
        value = item["value"]
        number = float(value.removesuffix("ms")) / 1000 if value.endswith("ms") else _px(value)
        result.append(MetricToken(item["name"], number, item["usage"]))
    return result


def load_tokens(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))
