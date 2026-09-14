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
            ),
        ],
    )

**每帧都要把这一帧要显示的棋子写全**（不是增量）——想演「谁没了」，就在下一帧里别写它。
坐标写 `(x, y)`：x 向右、y 向下，原点在左上角。

⚠ 阵营必须**写明**：`red("王")` / `green("步")`。这里没有棋规可以替你推断半场，
   写清楚了画面上才是你想要的颜色。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple, Union

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
    """

    text: str
    hold: float = DEFAULT_HOLD
    pieces: Mapping[_RawPoint, _CellMapValue] = field(default_factory=dict)
    highlights: Sequence[_RawPoint] = field(default_factory=list)
    arrows: Sequence[Mapping[str, Any]] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.pieces = _piece_map_json(self.pieces, "pieces")
        self.highlights = _point_list_json(self.highlights, "highlights")
        self.arrows = [dict(item) for item in self.arrows]
        try:
            self.hold = float(self.hold)
        except (TypeError, ValueError) as exc:  # pragma: no cover - 防御性
            raise DemoError(f"hold 不是数字：{self.hold!r}") from exc

    def to_json(self) -> Dict[str, Any]:
        return {
            "text": str(self.text),
            "hold": self.hold,
            "pieces": dict(self.pieces),
            "highlights": [list(item) for item in self.highlights],
            "arrows": [dict(item) for item in self.arrows],
        }


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
            for frame_index in range(len(demo.frames) - 1):
                first, second = demo.frames[frame_index], demo.frames[frame_index + 1]
                if _same_picture(first, second):
                    notes.append(
                        f"{symbol} 的第 {index + 1} 段：第 {frame_index + 1} 帧与第 {frame_index + 2} 帧"
                        f"画面完全一样（只差停留时间），多半是复制出来忘了改"
                    )
    return notes


def _same_picture(first: Frame, second: Frame) -> bool:
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
