# -*- coding: utf-8 -*-
"""「文字」页签的数据层：载入 / 改 / 撤销 / 校验 / 保存。

**这里不碰任何界面控件**，所以可以脱离窗口单独测（`tools/editor/selftest.py`）。

数据模型就是一份 `guide_text_kit.GuideText`：怎么玩那一页 + 小标题 + 每种棋子一页 +
容易搞错的那一页。页面用**页号**指认（`INTRO` / `PIECES_TITLE` / 兵种字 / `OUTRO`），
这样界面上「左边选页、右边改这一页」的写法与数据形状无关。

保存只做两件事：把 `tools/guide_text.py` 的剧本区重写一遍（`text_codegen`），
再刷新 `neo-two-kings/data/guide_text.json`（游戏读的那份）。
"""

from __future__ import annotations

import copy
import importlib
import sys
from pathlib import Path
from typing import List, Optional

TOOLS_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TOOLS_DIR.parent
#: 作者手写的文案（编辑器保存时只重写它的「剧本区」）。
SOURCE_PATH = TOOLS_DIR / "guide_text.py"
#: 游戏读的那份（由这里与 export_guide_text.py 刷新，别手改）。
JSON_PATH = REPO_ROOT / "neo-two-kings" / "data" / "guide_text.json"

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import guide_text_kit as kit  # noqa: E402  （必须在 sys.path 处理之后）
from editor import atomic, text_codegen  # noqa: E402

#: 三个非棋子的页号。棋子的页号就是它的显示字（王/弓/骑/盾/步）。
INTRO = "intro"
PIECES_TITLE = "pieces_title"
OUTRO = "outro"


# --------------------------------------------------------------------------------------
# 页面：页号 ↔ 数据
# --------------------------------------------------------------------------------------


def pages() -> List[str]:
    """左栏列出来的全部页，顺序＝界面上的顺序。"""
    return [INTRO, PIECES_TITLE, *kit.PIECE_SYMBOLS, OUTRO]


def page_kind(page: str) -> str:
    """这一页是什么：`intro` / `heading` / `piece` / `outro`。界面按它决定显示哪些字段。"""
    if page == INTRO:
        return "intro"
    if page == PIECES_TITLE:
        return "heading"
    if page == OUTRO:
        return "outro"
    return "piece"


def page_label(text: kit.GuideText, page: str) -> str:
    """左栏列表里那一行字（跟着标题走，改完标题一眼能看出来）。"""
    if page == INTRO:
        return text.intro_title or "（怎么玩的标题）"
    if page == PIECES_TITLE:
        return f"{text.pieces_title or '（小标题）'}（小标题）"
    if page == OUTRO:
        return text.outro_title or "（易错点的标题）"
    return page


def piece_of(text: kit.GuideText, page: str) -> Optional[kit.PieceText]:
    """棋子那一页的数据；页号不是棋子时返回 None。"""
    if page_kind(page) != "piece":
        return None
    return text.piece(page)


def points_of(text: kit.GuideText, page: str) -> List[str]:
    """这一页的正文列表（怎么玩 / 易错点 / 某种棋子）。

    「小标题」那一页只有一行字、没有正文，返回空列表——界面拿它决定要不要显示条目区。
    """
    kind = page_kind(page)
    if kind == "intro":
        return text.intro_points
    if kind == "outro":
        return text.outro_points
    if kind == "piece":
        piece = text.piece(page)
        return piece.points if piece is not None else []
    return []


def add_point(points: List[str], index: int, value: str = "") -> int:
    """在第 `index` 条**之前**插一条，返回新条目的下标。"""
    index = max(0, min(int(index), len(points)))
    points.insert(index, str(value))
    return index


def remove_point(points: List[str], index: int) -> bool:
    """删掉第 `index` 条；下标越界时什么都不做（返回 False）。"""
    if 0 <= index < len(points):
        points.pop(index)
        return True
    return False


def move_point(points: List[str], index: int, delta: int) -> int:
    """把第 `index` 条上移/下移一格，返回它移动之后的下标（移不动就原地不动）。"""
    target = index + int(delta)
    if 0 <= index < len(points) and 0 <= target < len(points):
        points[index], points[target] = points[target], points[index]
        return target
    return index


# --------------------------------------------------------------------------------------
# 文档：载入 / 撤销 / 校验 / 保存
# --------------------------------------------------------------------------------------


def _collect_fresh() -> kit.GuideText:
    """**重新从磁盘**导入 `tools/guide_text.py` 再取数据。

    为什么不能直接再调一次 `guide_text()`：Python 会把导入过的模块缓存起来，
    你在编辑器外手改了那个文件，点「重新载入」却什么都读不到，那就成了骗人的按钮。
    """
    for name in [key for key in list(sys.modules) if key == "guide_text"]:
        del sys.modules[name]
    importlib.invalidate_caches()
    import guide_text as module

    return module.guide_text()


class TextDoc:
    """内存里的整份文案 + 撤销栈 + 保存。界面只跟它打交道。"""

    UNDO_LIMIT = 60

    def __init__(self) -> None:
        self.text: kit.GuideText = _collect_fresh()
        self._undo: List[kit.GuideText] = []
        self._redo: List[kit.GuideText] = []
        self.reload()

    # --- 载入 ---
    def reload(self) -> None:
        self.text = _collect_fresh()
        self._undo.clear()
        self._redo.clear()

    # --- 撤销 ---
    def push_undo(self) -> None:
        self._undo.append(copy.deepcopy(self.text))
        if len(self._undo) > self.UNDO_LIMIT:
            self._undo.pop(0)
        self._redo.clear()

    def undo(self) -> bool:
        if not self._undo:
            return False
        self._redo.append(copy.deepcopy(self.text))
        self.text = self._undo.pop()
        return True

    def redo(self) -> bool:
        if not self._redo:
            return False
        self._undo.append(copy.deepcopy(self.text))
        self.text = self._redo.pop()
        return True

    def can_undo(self) -> bool:
        return bool(self._undo)

    def can_redo(self) -> bool:
        return bool(self._redo)

    # --- 校验 ---
    def problems(self) -> List[str]:
        return kit.validate(self.text)

    def warnings(self) -> List[str]:
        return kit.warnings(self.text)

    # --- 保存 ---
    def render_source(self) -> str:
        """`tools/guide_text.py` 的新源码（文件头的说明原样保留）。"""
        header = text_codegen.split_header(SOURCE_PATH.read_text(encoding="utf-8"))
        return text_codegen.render_module(header, self.text)

    def save(self) -> List[str]:
        """写回 `tools/guide_text.py` 并刷新 `data/guide_text.json`。返回做了些什么。"""
        problems = self.problems()
        if problems:
            raise ValueError("文案还有 %d 处问题，先改完再保存：\n- %s" % (len(problems), "\n- ".join(problems)))

        notes: List[str] = []
        source = self.render_source()
        # 先编译一遍（语法错就地拦下，别写坏磁盘上的文件）
        try:
            compile(source, str(SOURCE_PATH), "exec")
        except SyntaxError as exc:  # pragma: no cover - 正常不该发生
            raise ValueError(f"生成 {SOURCE_PATH.name} 时写出语法错误：第 {exc.lineno} 行 {exc.msg}") from exc

        if SOURCE_PATH.read_text(encoding="utf-8") != source:
            atomic.write_text(SOURCE_PATH, source)
            notes.append(f"写入 {SOURCE_PATH.name}")

        if kit.write(JSON_PATH, self.text):
            notes.append(f"刷新 {JSON_PATH.name}")
        else:
            notes.append(f"{JSON_PATH.name} 本来就是最新的")
        for note in self.warnings():
            notes.append(f"注意：{note}")
        return notes

    # --- 摘要（界面状态栏用） ---
    def summary(self) -> str:
        rows = kit.summary(self.text)
        points = sum(row[1] for row in rows)
        chars = sum(row[2] for row in rows)
        return f"{len(rows)} 页 / {points} 条 / {chars} 字"
