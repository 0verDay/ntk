# -*- coding: utf-8 -*-
"""可视化编辑器的数据层：载入 / 改 / 撤销 / 校验 / 保存。

**这里不碰任何界面控件**，所以可以脱离窗口单独测（`tools/editor/selftest.py`）。

数据模型简单到不用解释：一段动画 = 一帧一帧的**画面**，
每一帧自己带着「画哪几枚棋子、画哪几条箭头、高亮哪些格子、写哪句话、停多久、**镜头看哪几格**」。
没有棋规、没有推算、没有「上一帧的延续」——想演什么就把那一帧写成什么样。

镜头（`view`）是唯一一处「默认不是空」的东西：不写就是「按这一帧的内容自动推」，
写了就是作者说了算（游戏端只在 `view_of` / `canvas_of` 两处读它，见 tools/README.md）。
"""

from __future__ import annotations

import copy
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

TOOLS_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TOOLS_DIR.parent
DEMOS_DIR = TOOLS_DIR / "demos"
JSON_PATH = REPO_ROOT / "neo-two-kings" / "data" / "guide_demos.json"

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import guide_demo_kit as kit  # noqa: E402  （必须在 sys.path 处理之后）
from editor import codegen  # noqa: E402

Point = Tuple[int, int]
#: 新建帧时写进 text 的占位说明（校验要求每帧都有文字，省得一建出来就是红的）。
PLACEHOLDER_TEXT = "（这一帧的说明）"


# --------------------------------------------------------------------------------------
# 帧上的小操作（都是「换一份新的」，方便撤销快照干净）
# --------------------------------------------------------------------------------------


def key_of(cell: Point) -> str:
    return f"{cell[0]},{cell[1]}"


def point_of(key: Any) -> Point:
    if isinstance(key, (list, tuple)):
        return int(key[0]), int(key[1])
    x, y = str(key).split(",")
    return int(x), int(y)


def piece_at(frame: kit.Frame, cell: Point) -> Optional[List[Any]]:
    """这一帧在 `cell` 上画了什么（`[兵种字, 阵营]`）；空格返回 None。"""
    value = (frame.pieces or {}).get(key_of(cell))
    return list(value) if isinstance(value, (list, tuple)) else None


def set_piece(frame: kit.Frame, cell: Point, symbol: str, camp: str) -> None:
    pieces = dict(frame.pieces or {})
    pieces[key_of(cell)] = [str(symbol), str(camp)]
    frame.pieces = pieces


def erase_piece(frame: kit.Frame, cell: Point) -> None:
    pieces = dict(frame.pieces or {})
    pieces.pop(key_of(cell), None)
    frame.pieces = pieces


def has_highlight(frame: kit.Frame, cell: Point) -> bool:
    return list(cell) in [list(item) for item in (frame.highlights or [])]


def toggle_highlight(frame: kit.Frame, cell: Point) -> bool:
    """切换高亮，返回切换之后是不是亮的。"""
    points = [point_of(item) for item in (frame.highlights or [])]
    if cell in points:
        points.remove(cell)
        lit = False
    else:
        points.append(cell)
        lit = True
    frame.highlights = kit.points(points)
    return lit


def add_arrow(frame: kit.Frame, frm: Point, to: Point, style: str = "move") -> None:
    frame.arrows = list(frame.arrows or []) + [kit.arrow(frm, to, style)]


def remove_arrows_touching(frame: kit.Frame, cell: Point) -> int:
    """删掉所有「起点或终点落在这一格」的箭头，返回删了几条。"""
    kept = []
    removed = 0
    for item in frame.arrows or []:
        if point_of(item["from"]) == cell or point_of(item["to"]) == cell:
            removed += 1
            continue
        kept.append(dict(item))
    frame.arrows = kept
    return removed


def remove_arrow_at(frame: kit.Frame, index: int) -> None:
    arrows = list(frame.arrows or [])
    if 0 <= index < len(arrows):
        arrows.pop(index)
    frame.arrows = arrows


# --------------------------------------------------------------------------------------
# 镜头（显示范围）：`view = (x, y, w, h)`，不写 = 按这一帧的内容自动推
# --------------------------------------------------------------------------------------


def view_of(frame: kit.Frame) -> Optional[Tuple[int, int, int, int]]:
    """这一帧写死的镜头；没写返回 None（= 自动）。"""
    return frame.view_rect()


def set_view(frame: kit.Frame, x: int, y: int, w: int, h: int, size: int) -> None:
    """设定镜头。宽高必须为正、矩形必须落在棋盘里，否则抛 ValueError（界面会把话说给作者）。"""
    x, y, w, h = int(x), int(y), int(w), int(h)
    if w <= 0 or h <= 0:
        raise ValueError(f"镜头的宽高必须是正数（现在是 {w}×{h}）——写的是格子数，不是右下角坐标")
    if x < 0 or y < 0:
        raise ValueError(f"镜头的左上角不能是负数（现在是 ({x}, {y})）")
    if x + w > size or y + h > size:
        raise ValueError(
            f"镜头 ({x}, {y}) 起、{w}×{h} 会伸出棋盘：右下角到 ({x + w - 1}, {y + h - 1})，"
            f"而棋盘是 {size}×{size}"
        )
    frame.view = (x, y, w, h)


def clear_view(frame: kit.Frame) -> None:
    """恢复成「按内容自动推」。"""
    frame.view = None


def content_bounds(frame: kit.Frame) -> Tuple[int, int, int, int]:
    """这一帧内容（棋子 + 高亮 + 箭头两端）的紧致包围盒，`(x, y, w, h)`。

    给「按内容贴合」按钮用：它算出来的就是**没写 view 时游戏端会用的那个范围**
    （对应 GuideDemos.frame_bounds）。这一帧什么都没有时返回 1×1（至少框住一格，免得 0 宽高）。
    """
    cells: List[Point] = [point_of(key) for key in (frame.pieces or {})]
    cells += [point_of(item) for item in (frame.highlights or [])]
    for item in frame.arrows or []:
        cells.append(point_of(item["from"]))
        cells.append(point_of(item["to"]))
    if not cells:
        return (0, 0, 1, 1)
    xs = [cell[0] for cell in cells]
    ys = [cell[1] for cell in cells]
    x0, y0 = min(xs), min(ys)
    return (x0, y0, max(xs) - x0 + 1, max(ys) - y0 + 1)


def content_outside_view(frame: kit.Frame) -> List[str]:
    """这一帧有多少东西落在镜头外（编辑器用它在状态栏提醒，**不拦**）。

    复用 `kit` 里那份判断，免得编辑器与导出器对「装不下」有两套说法。
    返回人类可读的条目（`棋子(5, 5)` / `箭头 from(0, 0)`……）；空列表 = 都在镜头里。
    """
    view = frame.view_rect()
    if view is None:
        return []
    return kit.view_overflow(frame)


def new_frame_like(frame: Optional[kit.Frame] = None) -> kit.Frame:
    """新建一帧：沿用上一帧的棋子、高亮与**镜头**（改动通常只差一点），箭头和文字留空重写。

    镜头的沿用是刻意的：连着几帧通常用同一个视口，只有真正要换镜头的那一帧才去改它
    （不沿用的结果就是「每加一帧就得重新框一次镜头」）。

    没有上一帧时给一张空棋盘。
    """
    if frame is None:
        return kit.Frame(text=PLACEHOLDER_TEXT)
    return kit.Frame(
        text=PLACEHOLDER_TEXT,
        hold=float(frame.hold),
        # 复制成字面量，免得两帧共享同一个 dict（改一帧会连带改另一帧）
        pieces={point_of(key): list(value) for key, value in (frame.pieces or {}).items()},
        highlights=[point_of(item) for item in (frame.highlights or [])],
        arrows=[],
        view=tuple(frame.view) if frame.view is not None else None,
        view_hold=bool(frame.view_hold),
    )


def new_demo(size: int = 7) -> kit.Demo:
    """新建一段动画：一块空棋盘 + 一帧。"""
    return kit.Demo(caption="（新动画的标题）", size=size, frames=[kit.Frame(text=PLACEHOLDER_TEXT)])


def set_size(demo: kit.Demo, size: int) -> None:
    """改棋盘边长。有棋子或镜头会被挤出棋盘时拒绝，并说清是哪一帧。"""
    size = int(size)
    for index, frame in enumerate(demo.frames):
        for key in frame.pieces or {}:
            cell = point_of(key)
            if not (0 <= cell[0] < size and 0 <= cell[1] < size):
                raise ValueError(
                    f"第 {index + 1} 帧的 {cell} 上有棋子，缩到 {size}×{size} 会把它挤出棋盘；先把它擦掉"
                )
        for item in frame.highlights or []:
            cell = point_of(item)
            if not (0 <= cell[0] < size and 0 <= cell[1] < size):
                raise ValueError(f"第 {index + 1} 帧的高亮格 {cell} 会落在棋盘外；先取消它的高亮")
        view = frame.view_rect()
        if view is not None and (view[0] + view[2] > size or view[1] + view[3] > size):
            raise ValueError(
                f"第 {index + 1} 帧的镜头是 rect({view[0]}, {view[1]}, {view[2]}, {view[3]})，"
                f"缩到 {size}×{size} 会让它伸到棋盘外；先把那一帧的镜头改小或清掉"
            )
    demo.size = size


# --------------------------------------------------------------------------------------
# 文档：载入 / 撤销 / 校验 / 保存
# --------------------------------------------------------------------------------------


def _collect_fresh() -> Dict[str, List[kit.Demo]]:
    """**重新从磁盘**导入 demos 包再收集。

    为什么不能直接再调一次 `collect()`：Python 会把导入过的模块缓存起来，
    `collect()` 拿到的是**内存里**那份旧代码——你在编辑器外手改了 `tools/demos/*.py`，
    点「重新载入」却什么都读不到，那就成了骗人的按钮。这里把缓存清掉再导入。
    """
    import importlib

    for name in [key for key in list(sys.modules) if key == "demos" or key.startswith("demos.")]:
        del sys.modules[name]
    importlib.invalidate_caches()
    from demos import collect as fresh_collect

    return fresh_collect()


class Doc:
    """内存里的全部动画 + 撤销栈 + 保存。界面只跟它打交道。"""

    UNDO_LIMIT = 60

    def __init__(self) -> None:
        self.demos: Dict[str, List[kit.Demo]] = {}
        self._undo: List[Dict[str, List[kit.Demo]]] = []
        self._redo: List[Dict[str, List[kit.Demo]]] = []
        self.reload()

    # --- 载入 ---
    def reload(self) -> None:
        self.demos = _collect_fresh()
        self._undo.clear()
        self._redo.clear()

    def symbols(self) -> List[str]:
        return list(kit.PIECE_SYMBOLS)

    def module_path(self, symbol: str) -> Path:
        return DEMOS_DIR / f"{_MODULE_OF[symbol]}.py"

    # --- 撤销 ---
    def push_undo(self) -> None:
        self._undo.append(copy.deepcopy(self.demos))
        if len(self._undo) > self.UNDO_LIMIT:
            self._undo.pop(0)
        self._redo.clear()

    def undo(self) -> bool:
        if not self._undo:
            return False
        self._redo.append(copy.deepcopy(self.demos))
        self.demos = self._undo.pop()
        return True

    def redo(self) -> bool:
        if not self._redo:
            return False
        self._undo.append(copy.deepcopy(self.demos))
        self.demos = self._redo.pop()
        return True

    def can_undo(self) -> bool:
        return bool(self._undo)

    def can_redo(self) -> bool:
        return bool(self._redo)

    # --- 校验 ---
    def problems(self) -> List[str]:
        return kit.validate(self.demos)

    def warnings(self) -> List[str]:
        return kit.warnings(self.demos)

    # --- 保存 ---
    def render_modules(self) -> Dict[Path, str]:
        """每个兵种模块 → 新的源码（文件头的说明原样保留）。"""
        sources: Dict[Path, str] = {}
        for symbol, demos in self.demos.items():
            path = self.module_path(symbol)
            header = codegen.split_header(path.read_text(encoding="utf-8"))
            sources[path] = codegen.render_module(header, demos)
        return sources

    def save(self) -> List[str]:
        """写回 `tools/demos/*.py` 并刷新 `data/guide_demos.json`。返回做了些什么。"""
        problems = self.problems()
        if problems:
            raise ValueError("剧本还有 %d 处问题，先改完再保存：\n- %s" % (len(problems), "\n- ".join(problems)))

        notes: List[str] = []
        sources = self.render_modules()
        # 先全部编译一遍（语法错就地拦下，别写坏磁盘上的文件）
        for path, source in sources.items():
            try:
                compile(source, str(path), "exec")
            except SyntaxError as exc:  # pragma: no cover - 正常不该发生
                raise ValueError(f"生成 {path.name} 时写出语法错误：第 {exc.lineno} 行 {exc.msg}") from exc

        for path, source in sources.items():
            if path.read_text(encoding="utf-8") == source:
                continue
            _write_atomic(path, source)
            notes.append(f"写入 {path.name}")

        if kit.write(JSON_PATH, self.demos):
            notes.append(f"刷新 {JSON_PATH.name}")
        else:
            notes.append(f"{JSON_PATH.name} 本来就是最新的")
        for note in self.warnings():
            notes.append(f"注意：{note}")
        return notes

    # --- 摘要（界面状态栏用） ---
    def summary(self) -> str:
        rows = kit.summary(self.demos)
        demos = sum(row[1] for row in rows)
        frames = sum(row[2] for row in rows)
        seconds = sum(row[3] for row in rows)
        return f"{demos} 段动画 / {frames} 帧 / 共 {seconds:.1f} 秒"


#: 兵种字 → 模块名（`tools/demos/<名字>.py`）。
_MODULE_OF = {"王": "king", "弓": "archer", "骑": "knight", "盾": "shield", "步": "pawn"}


def _write_atomic(path: Path, text: str) -> None:
    """先写临时文件再替换：写一半崩掉也不会留下半个模块。"""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
