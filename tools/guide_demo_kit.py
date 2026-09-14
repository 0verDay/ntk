#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NeoTwoKings 棋子指南「动画」的作者库。

**每一帧就是一张画**：几枚棋子摆在哪、画哪几条箭头、哪些格子高亮、下面写哪句话、停多久。
游戏端只负责按顺序把这些帧画出来——它**不跑棋规**，所以你摆成什么样，画面上就是什么样。

数据流：

    tools/demos/*.py                     你写这里（棋子 / 箭头 / 高亮 / 文字 / 停留时间）
        ↓  python tools/export_guide_demos.py
    neo-two-kings/data/guide_demos.json  游戏读它（别手改）
        ↓  GuideDemos.load_demos() → GuideDemos.build()
    帧列表 → GuideDemo 画出来

## 一段动画长什么样

    Demo(
        caption = "整段动画的标题（画在棋盘下方，不参与动画）",
        size    = 7,                      # 棋盘边长
        frames  = [
            Frame(
                text      = "红王在 (0,0)：这一圈橙色就是王区",
                hold      = 2.0,          # 这一帧停多久（秒）
                pieces    = {(0, 0): red("王"), (1, 1): green("步")},
                highlights= [(0, 0), (1, 0), (0, 1), (1, 1)],
            ),
            Frame(
                text   = "王走上去吃掉它",
                hold   = 2.0,
                pieces = {(0, 0): red("王"), (1, 1): green("步")},
                arrows = [arrow((0, 0), (1, 1))],
                highlights=[(0, 0)],
                view   = rect(0, 0, 4, 4),   # 这一帧只看左上角 4×4（可不写，见下）
            ),
        ],
    )

**每帧都要把这一帧要显示的棋子写全**（不是增量）——想演「谁没了」，就在下一帧里别写它。
坐标写 `(x, y)`：x 向右、y 向下，原点在左上角。

## 显示范围（`view`）——镜头看哪几格

`view = rect(x, y, w, h)`：这一帧的镜头 = **左上角 (x, y)、宽 w 格、高 h 格**的矩形。
写了就完全按它显示（矩形外一律不画）；**不写就由这一帧的内容自动推**（棋子 + 高亮 + 箭头两端的包围盒）。

规则只有三条：

1. **舞台（画布）整段只有一个**，取全段各帧视口尺寸的**最大值**——所以文字排版不会抖。
2. 视口比舞台小的帧，画面**居中**放在舞台里（不会靠左上角）。想让镜头平移，就改 `view` 的 x/y。
3. 换帧时视口的移动/缩放有个 0.28 秒的过渡；想要「硬切」就写 `view_hold=True`。

视口装不下这一帧的棋子/箭头时**不拦**（导出只提醒一句），因为「故意裁掉画面外的棋子」也是表达方式。

⚠ 阵营必须**写明**：`red("王")` / `green("步")`。这里没有棋规可以替你推断半场，
   写清楚了画面上才是你想要的颜色。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple, Union

# --------------------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------------------

#: 五个兵种的显示字，同时也是一段动画的归属。顺序 = 指南页面里的顺序。
PIECE_SYMBOLS: Tuple[str, ...] = ("王", "弓", "骑", "盾", "步")

#: 阵营名。JSON 里写字符串，游戏端映射成 PieceInfo.Camp。
CAMPS: Tuple[str, ...] = ("red", "green")

#: 箭头的三种样式（游戏端按它选颜色）。
ARROW_STYLES: Tuple[str, ...] = ("move", "shot", "hop")
ARROW_STYLE_LABELS: Dict[str, str] = {
    "move": "移动（蓝）",
    "shot": "攻击（红）",
    "hop": "跳跃（紫）",
}

#: 高亮标签（游戏端只认这一个值）。
HIGHLIGHT_LABEL = "zone"

#: 一帧默认停多久（秒）。
DEFAULT_HOLD = 2.0

#: 剧本 JSON 的格式标记与版本，游戏端会核对。
FORMAT_TAG = "neo-two-kings/guide-frames"
FORMAT_VERSION = 2

Point = Tuple[int, int]
#: 矩形区域：`(x, y, w, h)`——左上角坐标 + 宽高（都是格子数，不是右下角坐标）。
Rect = Tuple[int, int, int, int]
_RawPoint = Union[Sequence[int], Point]
_CellMapValue = Union[str, Sequence[Any]]


class DemoError(Exception):
    """剧本写错了（坐标、棋子字、阵营、必填项……）。导出时会打印成人话。"""


# --------------------------------------------------------------------------------------
# 棋子 / 箭头
# --------------------------------------------------------------------------------------


def red(symbol: str) -> List[Any]:
    """红方棋子：`pieces={(0, 0): red("王")}`。"""
    return _camp_piece(symbol, "red")


def green(symbol: str) -> List[Any]:
    """绿方棋子：`pieces={(1, 1): green("步")}`。"""
    return _camp_piece(symbol, "green")


def _camp_piece(symbol: str, camp: str) -> List[Any]:
    _check_symbol(symbol, f"{camp}({symbol!r})")
    assert camp in CAMPS
    return [symbol, camp]


def arrow(frm: _RawPoint, to: _RawPoint, style: str = "move") -> Dict[str, Any]:
    """一条箭头：从 `frm` 指到 `to`。`style` 见 `ARROW_STYLES`（默认蓝色「移动」）。"""
    if style not in ARROW_STYLES:
        raise DemoError(f"箭头样式「{style}」不认识，只能是 {ARROW_STYLES}")
    return {"from": _point_json(frm, "arrow() 的起点"), "to": _point_json(to, "arrow() 的终点"), "style": style}


def rect(x: Any, y: Any, w: Any, h: Any) -> Rect:
    """一个矩形区域：左上角 `(x, y)`、宽 `w` 格、高 `h` 格。

    只用来写 `Frame(view=...)`（这一帧的镜头范围）。`w`/`h` 是**格子数**不是右下角坐标，
    所以 `rect(0, 0, 4, 4)` 覆盖 (0,0)~(3,3) 这 16 格。
    """
    return (_plain_int(x, "rect() 的 x"), _plain_int(y, "rect() 的 y"),
            _plain_int(w, "rect() 的宽"), _plain_int(h, "rect() 的高"))


# --------------------------------------------------------------------------------------
# 基础校验
# --------------------------------------------------------------------------------------


def _check_size(size: Any) -> int:
    if isinstance(size, bool) or not isinstance(size, int):
        raise DemoError(f"size 必须是整数，收到 {size!r}")
    if not 2 <= size <= 16:
        raise DemoError(f"size 应该在 2~16 之间，收到 {size}")
    return size


def _check_symbol(symbol: Any, where: str) -> str:
    symbol = str(symbol)
    if len(symbol) != 1 or symbol not in PIECE_SYMBOLS:
        raise DemoError(
            f"{where} 的棋子字「{symbol}」不认识，只能是 {'/'.join(PIECE_SYMBOLS)} 中的一个字"
        )
    return symbol


def _check_inside(point: Point, size: int, where: str) -> None:
    x, y = point
    if not (0 <= x < size and 0 <= y < size):
        raise DemoError(f"{where} 的坐标 ({x}, {y}) 落在 {size}×{size} 棋盘之外")


def _point(value: Any, where: str) -> Point:
    if isinstance(value, (list, tuple)) and len(value) == 2:
        x, y = value
        if isinstance(x, bool) or isinstance(y, bool) or not isinstance(x, int) or not isinstance(y, int):
            raise DemoError(f"{where} 必须是整数坐标 (x, y)，收到 {value!r}")
        return (x, y)
    raise DemoError(f"{where} 必须是 (x, y) 形式的坐标，收到 {value!r}")


def _point_json(value: Any, where: str) -> List[int]:
    x, y = _point(value, where)
    return [x, y]


def _plain_int(value: Any, where: str) -> int:
    """给 `rect()` 用：**不做范围判断**，只挡住 bool / 字符串这种明显写错的类型。

    「矩形是不是在棋盘里、宽高是不是正数」由 `Frame.__post_init__` / `validate()` 说人话地报，
    所以这里不抛异常——`rect()` 只是个构造器，写在模块顶层炸掉会很难查。
    """
    if isinstance(value, bool) or not isinstance(value, int):
        try:
            return int(value)
        except (TypeError, ValueError):
            return 0
    return value


def _view_json(value: Any, where: str) -> List[int]:
    """`view=` 的归一化：接受 `rect(...)` / 4 元组 / 4 元列表，一律变成 `[x, y, w, h]`。"""
    if isinstance(value, (list, tuple)) and len(value) == 4:
        return [_plain_int(item, f"{where}[{index}]") for index, item in enumerate(value)]
    raise DemoError(f"{where} 必须写成 rect(x, y, w, h) 或 (x, y, w, h) 四元组，收到 {value!r}")


def _view_of(frame: "Frame") -> Tuple[int, int, int, int]:
    """帧的视口 `(x, y, w, h)`；没写视口时抛 KeyError（调用方自己判断 has_view）。"""
    value = frame.view
    return (int(value[0]), int(value[1]), int(value[2]), int(value[3]))


def _point_list_json(values: Any, where: str) -> List[List[int]]:
    if values is None:
        return []
    if not isinstance(values, (list, tuple)):
        raise DemoError(f"{where} 必须是坐标列表，收到 {values!r}")
    out: List[List[int]] = []
    for index, item in enumerate(values):
        point = _point_json(item, f"{where}[{index}]")
        if point not in out:  # 同一个格子写两遍没意义，去掉
            out.append(point)
    return out


def _piece_map_json(mapping: Any, where: str) -> Dict[str, Any]:
    """`{(x, y): red("步")}` → `{"x,y": ["步", "red"]}`。

    阵营**必须**写明（没有棋规可以替你推半场），所以这里不接受光写一个棋子字。
    """
    if mapping is None:
        return {}
    if not isinstance(mapping, Mapping):
        raise DemoError(f"{where} 必须是 {{(x, y): 棋子}} 这样的字典，收到 {mapping!r}")
    out: Dict[str, Any] = {}
    for raw_point, value in mapping.items():
        x, y = _point(raw_point, f"{where} 的格子")
        key = f"{x},{y}"
        if not isinstance(value, (list, tuple)) or len(value) != 2:
            raise DemoError(
                f"{where}[{key}] 要写成 red(\"王\") 或 green(\"步\")——"
                f"每一帧都要写明阵营（这里没有棋规替你推半场），收到 {value!r}"
            )
        symbol, camp = value[0], value[1]
        _check_symbol(symbol, f"{where}[{key}]")
        if camp not in CAMPS:
            raise DemoError(f"{where}[{key}] 的阵营只能是 {CAMPS}，收到 {camp!r}")
        out[key] = [str(symbol), str(camp)]
    return out


def cells_of_pieces(pieces: Mapping[str, Any]) -> Dict[Point, str]:
    """`{"x,y": ["步","red"]}` → `{(x, y): "步"}`（编辑器画棋盘用）。"""
    out: Dict[Point, str] = {}
    for key, value in (pieces or {}).items():
        x, y = str(key).split(",")
        out[(int(x), int(y))] = str(value[0]) if isinstance(value, (list, tuple)) else str(value)
    return out


def point(value: _RawPoint) -> List[int]:
    """`(x, y)` → `[x, y]`（JSON 形态）。直接改帧字典/字段时用它写坐标。"""
    return _point_json(value, "point()")


def points(values: Optional[Sequence[_RawPoint]]) -> List[List[int]]:
    """一串格子 → `[[x, y], …]`（JSON 形态），顺手去重。"""
    return _point_list_json(values, "points()")


# --------------------------------------------------------------------------------------
# 帧与演示
# --------------------------------------------------------------------------------------


@dataclass
class Frame:
    """一帧＝一张画。

    * `text`        棋盘下方那句话（**必须有**，空白帧就是观众只看到棋盘在动）
    * `hold`        这一帧停多久（秒，> 0）
    * `pieces`      `{(x, y): red("王")}`：这一帧要显示的**全部**棋子（不是增量）
    * `highlights`  高亮的格子（橙色）
    * `arrows`      `arrow((0,0), (1,1))` 画出来的箭头
    * `view`        这一帧的镜头范围 `rect(x, y, w, h)`；**不写就按内容自动推**
    * `view_hold`   换到这一帧时视口不做 0.28 秒过渡，直接硬切
    """

    text: str
    hold: float = DEFAULT_HOLD
    pieces: Mapping[_RawPoint, _CellMapValue] = field(default_factory=dict)
    highlights: Sequence[_RawPoint] = field(default_factory=list)
    arrows: Sequence[Mapping[str, Any]] = field(default_factory=list)
    view: Optional[Any] = None
    view_hold: bool = False

    def __post_init__(self) -> None:
        self.pieces = _piece_map_json(self.pieces, "pieces")
        self.highlights = _point_list_json(self.highlights, "highlights")
        self.arrows = [dict(item) for item in self.arrows]
        try:
            self.hold = float(self.hold)
        except (TypeError, ValueError) as exc:  # pragma: no cover - 防御性
            raise DemoError(f"hold 不是数字：{self.hold!r}") from exc
        if self.view is not None:
            self.view = _view_json(self.view, "view")
            x, y, w, h = _view_of(self)
            if w <= 0 or h <= 0:
                raise DemoError(f"view 的宽高必须是正数（收到 w={w}, h={h}）——它是格子数，不是右下角坐标")
            if x < 0 or y < 0:
                raise DemoError(f"view 的左上角不能是负数（收到 x={x}, y={y}）")
        self.view_hold = bool(self.view_hold)

    def has_view(self) -> bool:
        return self.view is not None

    def view_rect(self) -> Optional[Tuple[int, int, int, int]]:
        """`(x, y, w, h)`；没写视口时返回 None。"""
        return _view_of(self) if self.has_view() else None

    def to_json(self) -> Dict[str, Any]:
        data: Dict[str, Any] = {
            "text": str(self.text),
            "hold": self.hold,
            "pieces": dict(self.pieces),
            "highlights": [list(item) for item in self.highlights],
            "arrows": [dict(item) for item in self.arrows],
        }
        if self.has_view():
            data["view"] = [int(item) for item in _view_of(self)]
            if self.view_hold:
                data["view_hold"] = True
        return data


@dataclass
class Demo:
    """一段动画：一块棋盘 + 一帧一帧往下演。

    `size` 只决定棋盘多大（不再决定双方半场——阵营是每枚棋子自己写明的）。
    """

    caption: str
    size: int = 7
    frames: List[Frame] = field(default_factory=list)
    #: 出错时显示来源，由 tools/demos/__init__.py 填。
    source: str = ""

    def __post_init__(self) -> None:
        self.size = _check_size(self.size)
        self.frames = list(self.frames)

    def to_json(self) -> Dict[str, Any]:
        return {
            "caption": str(self.caption),
            "size": self.size,
            "frames": [frame.to_json() for frame in self.frames],
        }


# --------------------------------------------------------------------------------------
# 校验
# --------------------------------------------------------------------------------------


def validate(demos_by_symbol: Mapping[str, Sequence[Demo]]) -> List[str]:
    """返回所有问题（空列表 = 全部通过）。有问题的剧本导出会被拒绝。"""
    problems: List[str] = []
    missing = [s for s in PIECE_SYMBOLS if s not in demos_by_symbol]
    if missing:
        problems.append(f"缺少这些兵种的动画：{'、'.join(missing)}")
    unknown = [s for s in demos_by_symbol if s not in PIECE_SYMBOLS]
    if unknown:
        problems.append(f"这些兵种名不认识：{'、'.join(sorted(unknown))}（只能是 {'/'.join(PIECE_SYMBOLS)}）")

    for symbol in PIECE_SYMBOLS:
        for index, demo in enumerate(demos_by_symbol.get(symbol, ())):
            _validate_demo(problems, f"{symbol} 的第 {index + 1} 段", demo)
    return problems


def _validate_demo(problems: List[str], where: str, demo: Demo) -> None:
    if not str(demo.caption).strip():
        problems.append(f"{where}：caption 是空的（每段动画都要有一句话说明）")
    if not demo.frames:
        problems.append(f"{where}：一帧都没有")
    for index, frame in enumerate(demo.frames):
        _validate_frame(problems, f"{where} 的第 {index + 1} 帧", frame, demo.size)


def _validate_frame(problems: List[str], where: str, frame: Frame, size: int) -> None:
    if not str(frame.text).strip():
        problems.append(f"{where}：没写 text——空白帧就是观众只看到棋盘在动，不知道在演什么")
    if not frame.hold > 0:
        problems.append(f"{where}：hold 必须大于 0（现在是 {frame.hold}）")
    if frame.has_view():
        x, y, w, h = frame.view_rect()  # type: ignore[misc]
        if x + w > size or y + h > size:
            problems.append(
                f"{where}：view 是 rect({x}, {y}, {w}, {h})，右下角到 ({x + w - 1}, {y + h - 1})，"
                f"超出了 {size}×{size} 棋盘"
            )
    for key in frame.pieces:
        try:
            _check_inside(_parse_key(key), size, f"{where} 的棋子")
        except DemoError as exc:
            problems.append(str(exc))
    for point in frame.highlights:
        try:
            _check_inside(tuple(point), size, f"{where} 的高亮格")
        except DemoError as exc:
            problems.append(str(exc))
    for item in frame.arrows:
        style = str(item.get("style", "move"))
        if style not in ARROW_STYLES:
            problems.append(f"{where}：箭头样式「{style}」不认识（只能是 {'/'.join(ARROW_STYLES)}）")
        for end in ("from", "to"):
            if end not in item:
                problems.append(f"{where}：箭头缺少 {end}")
                continue
            try:
                _check_inside(tuple(item[end]), size, f"{where} 箭头的 {end}")
            except DemoError as exc:
                problems.append(str(exc))


def warnings(demos_by_symbol: Mapping[str, Sequence[Demo]]) -> List[str]:
    """不拦保存、但值得看一眼的问题。"""
    notes: List[str] = []
    for symbol in PIECE_SYMBOLS:
        for index, demo in enumerate(demos_by_symbol.get(symbol, ())):
            for frame_index, frame in enumerate(demo.frames):
                notes.extend(_view_overflow_notes(symbol, index, frame_index, frame))
            for frame_index in range(len(demo.frames) - 1):
                first, second = demo.frames[frame_index], demo.frames[frame_index + 1]
                if _same_picture(first, second):
                    notes.append(
                        f"{symbol} 的第 {index + 1} 段：第 {frame_index + 1} 帧与第 {frame_index + 2} 帧"
                        f"画面完全一样（只差停留时间），多半是复制出来忘了改"
                    )
    return notes


def _view_overflow_notes(symbol: str, demo_index: int, frame_index: int, frame: Frame) -> List[str]:
    """写了 view、但这一帧有东西落在视口外——**只提醒，不拦**。

    「故意把画面外的棋子裁掉」也是一种表达（比如只想让观众看局部），所以这里不下判决，
    只把「文字里提到的东西其实看不见」这类事故摆到作者面前。
    """
    if not frame.has_view():
        return []
    outside = view_overflow(frame)
    if not outside:
        return []
    x, y, w, h = frame.view_rect()  # type: ignore[misc]
    shown = "、".join(outside)
    return [
        f"{symbol} 的第 {demo_index + 1} 段第 {frame_index + 1} 帧：view 是 rect({x}, {y}, {w}, {h})，"
        f"但这些东西在视口外、画面上看不到——{shown}（有意裁掉就忽略这条）"
    ]


def view_overflow(frame: Frame) -> List[str]:
    """视口外的东西，形如 `['棋子(5, 5)', '箭头 to(0, 0)']`；没写 view 时返回空。

    导出器的警告与编辑器状态栏共用这一份判断，免得两边说法不一致。
    """
    view = frame.view_rect()
    if view is None:
        return []
    x, y, w, h = view

    def inside(cell: Tuple[int, int]) -> bool:
        return x <= cell[0] < x + w and y <= cell[1] < y + h

    outside: List[str] = []
    for key in frame.pieces:
        cell = _parse_key(key)
        if not inside(cell):
            outside.append(f"棋子{cell}")
    for item in frame.highlights:
        cell = (int(item[0]), int(item[1]))
        if not inside(cell):
            outside.append(f"高亮{cell}")
    for item in frame.arrows:
        for end in ("from", "to"):
            if end not in item:
                continue
            cell = (int(item[end][0]), int(item[end][1]))
            if not inside(cell):
                outside.append(f"箭头{end}{cell}")
    return list(dict.fromkeys(outside))  # 同一格被两样东西提到时只说一次


def _same_picture(first: Frame, second: Frame) -> bool:
    # 刻意**不管 view**：同一张画换个镜头看（文字往往也换了）是正常表达，不该报「复制忘改」。
    return (
        str(first.text) == str(second.text)
        and dict(first.pieces) == dict(second.pieces)
        and [list(item) for item in first.highlights] == [list(item) for item in second.highlights]
        and [dict(item) for item in first.arrows] == [dict(item) for item in second.arrows]
    )


def _parse_key(key: Any) -> Point:
    if isinstance(key, (list, tuple)) and len(key) == 2:
        return int(key[0]), int(key[1])
    x, y = str(key).split(",")
    return int(x), int(y)


# --------------------------------------------------------------------------------------
# 序列化
# --------------------------------------------------------------------------------------


def payload(demos_by_symbol: Mapping[str, Sequence[Demo]]) -> Dict[str, Any]:
    demos: Dict[str, Any] = {}
    for symbol in PIECE_SYMBOLS:
        if symbol in demos_by_symbol:
            demos[symbol] = [demo.to_json() for demo in demos_by_symbol[symbol]]
    return {
        "format": FORMAT_TAG,
        "version": FORMAT_VERSION,
        "generator": "tools/export_guide_demos.py",
        "warning": "这个文件由 Python 工具生成，不要手改；改动画请改 tools/demos/*.py 再跑一次导出。",
        "demos": demos,
    }


def dumps(demos_by_symbol: Mapping[str, Sequence[Demo]]) -> str:
    return _compact_arrays(json.dumps(payload(demos_by_symbol), ensure_ascii=False, indent=2)) + "\n"


def write(path: Union[str, Path], demos_by_symbol: Mapping[str, Sequence[Demo]]) -> bool:
    """写出 JSON；返回「内容是否真的变了」。"""
    path = Path(path)
    text = dumps(demos_by_symbol)
    old = path.read_text(encoding="utf-8") if path.exists() else None
    if old == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return True


def summary(demos_by_symbol: Mapping[str, Sequence[Demo]]) -> List[Tuple[str, int, int, float]]:
    """给导出脚本打表格用：(兵种, 段数, 帧数, 总秒数)。"""
    rows: List[Tuple[str, int, int, float]] = []
    for symbol in PIECE_SYMBOLS:
        demos = demos_by_symbol.get(symbol, ())
        if not demos:
            continue
        frames = sum(len(demo.frames) for demo in demos)
        seconds = sum(frame.hold for demo in demos for frame in demo.frames)
        rows.append((symbol, len(demos), frames, seconds))
    return rows


#: 坐标 `[0, 0]`、棋子 `["步", "red"]` 这类短数组让它们待在一行里（不然一份 JSON 几百行没法扫）。
_LEAF_ARRAY = re.compile(r"\[\s*([^\[\]{}]*?)\s*\]", re.S)
_GROUPED_ARRAY = re.compile(r"\[\s*((?:\[[^\[\]]*\](?:\s*,\s*|\s*))+)\]", re.S)
_COMPACT_MAX = 40


def _compact_arrays(text: str) -> str:
    def squeeze(match: "re.Match[str]") -> str:
        inner = " ".join(match.group(1).split())
        if not inner or len(inner) > _COMPACT_MAX:
            return match.group(0)
        return f"[{inner}]"

    return _GROUPED_ARRAY.sub(squeeze, _LEAF_ARRAY.sub(squeeze, text))
