# -*- coding: utf-8 -*-
"""把 Demo 对象渲染回 `tools/demos/*.py` 的源码——可视化编辑器保存时用它。

规矩只有一条：**只重写「剧本区」那一段**。文件开头的人类说明（模块 docstring）与 import
原样保留，所以「为什么这么摆位、这个坑怎么来的」那些话永远留在你手写的那一半里。

所以每个模块长这样：

    # -*- coding: utf-8 -*-
    \"\"\"大段说明……（编辑器和导出器都不动这一段）\"\"\"

    from guide_demo_kit import Demo, Frame, red, green, arrow

    SYMBOL = "王"

    # --- 剧本区开始：以下由 tools/editor 改写（手改这里的格式会在下次保存时被覆盖）---
    def demos():
        return [
            Demo(...),
        ]
    # --- 剧本区结束 ---

渲染是**确定性**的：同一份数据永远得到同一段源码，所以「保存一次」不会带来莫名其妙的
格式漂移。`tools/editor/selftest.py` 拿它当自检：载入 → 渲染 → 必须与原文件逐字节一致。
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import guide_demo_kit as _kit
from guide_demo_kit import ARROW_STYLES, DEFAULT_HOLD, Demo, Frame

MARKER_BEGIN = "# --- 剧本区开始：以下由 tools/editor 改写（手改这里的格式会在下次保存时被覆盖）---"
MARKER_END = "# --- 剧本区结束 ---"

#: 还没有标记的老模块（第一次交给编辑器时）：切到第一个 `def demos()` 之前。
_LEGACY_CUT = re.compile(r"^def demos\(\)", re.M)

#: 可能从 guide_demo_kit 里 import 的名字（按这个顺序排 import 行）。
#: 只有在这个名单里的名字才会被保留/补上——老版本用过的 `Phase`、`shots` 之类会被顺手清掉。
_KIT_NAMES = [
    "Demo", "Frame", "red", "green", "arrow",
    "ARROW_STYLES", "ARROW_STYLE_LABELS", "PIECE_SYMBOLS", "CAMPS",
    "DEFAULT_HOLD", "HIGHLIGHT_LABEL", "cells_of_pieces", "point", "points", "DemoError",
]
_IMPORT_RE = re.compile(r"^from guide_demo_kit import (.*)$", re.M)


# --------------------------------------------------------------------------------------
# 文件切分与组装
# --------------------------------------------------------------------------------------


def split_header(text: str) -> str:
    """取出「剧本区」之前的部分（说明、import、SYMBOL 都在这里）。

    已经有标记就按标记切；老模块（还没标记）切到第一个 `def demos()` 之前，
    这样第一次交给编辑器时也能把说明原样留住。
    """
    index = text.find(MARKER_BEGIN)
    if index >= 0:
        return text[:index]
    match = _LEGACY_CUT.search(text)
    if match:
        return text[: match.start()]
    return text


def render_module(header: str, demos: Sequence[Demo]) -> str:
    """`header`（说明、SYMBOL 原样保留）+ 重新渲染的剧本区。

    唯一会动 header 的地方是 `from guide_demo_kit import …` 那一行：在编辑器里用到新的名字
    （比如第一次画箭头要用 `arrow`）时，这行不跟着变的话，生成的模块一 import 就 NameError。
    规矩是：**只保留这个库真有的名字**，缺的补上，已经不存在的老名字（`Phase`、`shots`…）清掉。
    """
    block: List[str] = ["def demos():", "    return ["]
    for demo in demos:
        block.extend(render_demo(demo, "        "))
    block.append("    ]")

    header = _sync_imports(header, _needed_names("\n".join(block)))
    lines = [header.rstrip("\n"), "", MARKER_BEGIN, *block, "", "", MARKER_END]
    return "\n".join(lines) + "\n"


def _needed_names(source: str) -> set:
    """源码里真正当作函数调用/带下标使用的那些名字（`Demo(`、`arrow(`、`red(`…）。"""
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
    line = "from guide_demo_kit import " + ", ".join(ordered)
    return header[: match.start()] + line + header[match.end():]


# --------------------------------------------------------------------------------------
# 渲染
# --------------------------------------------------------------------------------------


def render_demo(demo: Demo, indent: str) -> List[str]:
    inner = indent + "    "
    lines = [f"{indent}Demo(", f"{inner}caption={_quote(demo.caption)},"]
    lines.append(f"{inner}size={demo.size},")
    lines.append(f"{inner}frames=[")
    for frame in demo.frames:
        lines.extend(_render_frame(frame, inner + "    "))
    lines.extend([f"{inner}],", f"{indent}),"])
    return lines


def _render_frame(frame: Frame, indent: str) -> List[str]:
    inner = indent + "    "
    lines = [f"{indent}Frame(", f"{inner}text={_quote(frame.text)},"]
    if abs(float(frame.hold) - float(DEFAULT_HOLD)) > 1e-9:
        lines.append(f"{inner}hold={_number(float(frame.hold))},")
    if frame.pieces:
        lines.extend(_render_pieces(frame.pieces, inner))
    if frame.highlights:
        lines.append(f"{inner}highlights={_points_literal(frame.highlights)},")
    if frame.arrows:
        lines.append(f"{inner}arrows=[")
        for item in frame.arrows:
            lines.append(f"{inner}    {_render_arrow(item)},")
        lines.append(f"{inner}],")
    lines.append(f"{indent}),")
    return lines


def _render_pieces(pieces: Mapping[str, Any], indent: str) -> List[str]:
    lines = [f"{indent}pieces={{"]
    for key in sorted(pieces.keys(), key=_parse_key):
        lines.append(f"{indent}    {_cell_key_literal(key)}: {_piece_literal(pieces[key])},")
    lines.append(f"{indent}}},")
    return lines


def _render_arrow(item: Mapping[str, Any]) -> str:
    start = _point_literal(item["from"])
    end = _point_literal(item["to"])
    style = str(item.get("style", ARROW_STYLES[0]))
    if style == ARROW_STYLES[0]:
        return f"arrow({start}, {end})"
    return f"arrow({start}, {end}, {_quote(style)})"


# --------------------------------------------------------------------------------------
# 字面量
# --------------------------------------------------------------------------------------


def _quote(text: str) -> str:
    escaped = (
        str(text)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def _number(value: float) -> str:
    """用 repr 保证原样往返（2.0 → "2.0"、1.075 → "1.075"），不做四舍五入。"""
    return repr(float(value))


def _point_literal(value: Any) -> str:
    x, y = _parse_pair(value)
    return f"({x}, {y})"


def _points_literal(values: Sequence[Any]) -> str:
    return "[" + ", ".join(_point_literal(item) for item in values) + "]"


def _cell_key_literal(key: Any) -> str:
    x, y = _parse_key(key)
    return f"({x}, {y})"


def _piece_literal(value: Any) -> str:
    symbol, camp = value[0], value[1]
    builder = "red" if camp == "red" else "green"
    return f"{builder}({_quote(str(symbol))})"


def _parse_key(key: Any) -> Tuple[int, int]:
    if isinstance(key, (list, tuple)) and len(key) == 2:
        return int(key[0]), int(key[1])
    x, y = str(key).split(",")
    return int(x), int(y)


def _parse_pair(value: Any) -> Tuple[int, int]:
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return int(value[0]), int(value[1])
    raise ValueError(f"不是坐标：{value!r}")
