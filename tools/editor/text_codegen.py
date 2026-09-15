# -*- coding: utf-8 -*-
"""把 GuideText 对象渲染回 `tools/guide_text.py` 的源码——「文字」页签保存时用它。

规矩和动画那边（`editor/codegen.py`）一模一样：**只重写「剧本区」那一段**，
文件开头的人类说明与 import 原样保留，所以你写下的「为什么这句话这么说」永远留在文件里。

    文件结构：

        # -*- coding: utf-8 -*-
        \"\"\"大段说明……（编辑器和导出器都不动这一段）\"\"\"

        from guide_text_kit import GuideText, PieceText

        # --- 剧本区开始：以下由 tools/editor 改写（手改这里的格式会在下次保存时被覆盖）---
        def guide_text():
            return GuideText(
                intro_title="怎么玩",
                …
            )
        # --- 剧本区结束 ---

渲染是**确定性**的：同一份数据永远得到同一段源码，所以「打开什么都不改就保存」不会产生
无谓改动（`tools/editor/selftest.py` 拿这一点当自检）。
"""

from __future__ import annotations

import re
from typing import Any, List, Sequence

from guide_text_kit import GuideText, PieceText

MARKER_BEGIN = "# --- 剧本区开始：以下由 tools/editor 改写（手改这里的格式会在下次保存时被覆盖）---"
MARKER_END = "# --- 剧本区结束 ---"

#: 还没有标记的老文件（第一次交给编辑器时）：切到第一个 `def guide_text()` 之前。
_LEGACY_CUT = re.compile(r"^def guide_text\(\)", re.M)

#: 可能从 guide_text_kit 里 import 的名字（按这个顺序排 import 行）。
_KIT_NAMES = ["GuideText", "PieceText"]
_IMPORT_RE = re.compile(r"^from guide_text_kit import (.*)$", re.M)

#: 字段顺序＝渲染顺序＝文件里的顺序。固定下来，渲染才会稳定。
_FIELDS = (
    "intro_title",
    "intro_points",
    "intro_card_glyph",
    "intro_card_short",
    "pieces_title",
    "pieces",
    "outro_title",
    "outro_points",
)


# --------------------------------------------------------------------------------------
# 文件切分与组装
# --------------------------------------------------------------------------------------


def split_header(text: str) -> str:
    """取出「剧本区」之前的部分（说明、import 都在这里）。"""
    index = text.find(MARKER_BEGIN)
    if index >= 0:
        return text[:index]
    match = _LEGACY_CUT.search(text)
    if match:
        return text[: match.start()]
    return text


def render_module(header: str, text: GuideText) -> str:
    """`header`（说明原样保留）+ 重新渲染的剧本区。"""
    block: List[str] = ["def guide_text():", "    return GuideText("]
    block.extend(render_text(text, "        "))
    block.append("    )")

    header = _sync_imports(header, _needed_names("\n".join(block)))
    lines = [header.rstrip("\n"), "", MARKER_BEGIN, *block, "", "", MARKER_END]
    return "\n".join(lines) + "\n"


def _needed_names(source: str) -> set:
    found = set()
    for name in _KIT_NAMES:
        if re.search(rf"\b{re.escape(name)}\b", source):
            found.add(name)
    return found


def _sync_imports(header: str, needed: set) -> str:
    match = _IMPORT_RE.search(header)
    if not match:
        return header
    existing = [name.strip() for name in match.group(1).split(",") if name.strip()]
    names = {name for name in existing if name in _KIT_NAMES} | {name for name in needed if name in _KIT_NAMES}
    ordered = sorted(names, key=lambda name: (_KIT_NAMES.index(name) if name in _KIT_NAMES else 99, name))
    line = "from guide_text_kit import " + ", ".join(ordered)
    return header[: match.start()] + line + header[match.end():]


# --------------------------------------------------------------------------------------
# 渲染
# --------------------------------------------------------------------------------------


def render_text(text: GuideText, indent: str) -> List[str]:
    """`GuideText(...)` 里面的那些字段行（不含最后那个右括号）。"""
    lines: List[str] = []
    for name in _FIELDS:
        value: Any = getattr(text, name)
        if name == "pieces":
            lines.append(f"{indent}pieces=[")
            for piece in value:
                lines.extend(_render_piece(piece, indent + "    "))
            lines.append(f"{indent}],")
        elif isinstance(value, (list, tuple)):
            lines.extend(_render_lines(name, list(value), indent))
        else:
            lines.append(f"{indent}{name}={_quote(value)},")
    return lines


def _render_piece(piece: PieceText, indent: str) -> List[str]:
    inner = indent + "    "
    lines = [f"{indent}PieceText(", f"{inner}symbol={_quote(piece.symbol)},"]
    lines.append(f"{inner}short={_quote(piece.short)},")
    lines.append(f"{inner}tagline={_quote(piece.tagline)},")
    lines.extend(_render_lines("points", list(piece.points), inner))
    lines.append(f"{indent}),")
    return lines


def _render_lines(name: str, values: Sequence[str], indent: str) -> List[str]:
    lines = [f"{indent}{name}=["]
    for value in values:
        lines.append(f"{indent}    {_quote(value)},")
    lines.append(f"{indent}],")
    return lines


def _quote(value: Any) -> str:
    escaped = (
        str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'
