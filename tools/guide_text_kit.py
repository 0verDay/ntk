#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NeoTwoKings 棋子指南「纯文本」的作者库：数据模型 + 校验 + 序列化。

游戏里所有说明文字都来自这里（经 `tools/export_guide_text.py` 导出成 JSON 再被游戏读）：

    tools/guide_text.py                     你写这里（标题 / 摘要 / 一条条的正文）
        ↓  python tools/export_guide_text.py
    neo-two-kings/data/guide_text.json      游戏读它（别手改）
        ↓  GuideText.load_text() → PieceGuide（门面）
    guide.gd 排版成页面 / game.gd 的长按卡片

## 一份指南长什么样

    GuideText(
        intro_title     = "怎么玩",
        intro_points    = ["7×7 棋盘，……", "双方轮流走子。……"],
        intro_card_glyph= "棋",          # 左栏那张卡上的大字（正好一个字）
        intro_card_short= "规则总览",     # 左栏那张卡上的一句话
        pieces_title    = "五种棋子",     # 左栏里棋子卡上方的小标题
        pieces = [
            PieceText(
                symbol  = "王",          # 用显示字指认（王/弓/骑/盾/步），和棋盘上的字同一套
                short   = "角落里的近战", # 左栏那张速查卡上的一句话（越短越好）
                tagline = "只能在自己角落的 2×2 里挪动，靠走上去直接吃子。",
                points  = ["移动：……", "吃子：……"],
            ),
            …四种…
        ],
        outro_title     = "几个容易搞错的点",
        outro_points    = ["「结算」不等于「走子」：……"],
    )

## 几条约定

* **界面自己会加「・」**：`points` 里每条是一句话，别在开头自己写 `・`/`-`（导出会提醒）。
* `short` 是左栏速查卡上那一行，超过 6 个汉字导出会提醒（卡片只有 160 像素宽）。
* 棋子用**显示字**指认；写了别的字（或漏了某个兵种）导出会拦下来。
* 改完**一定要跑一次导出**，否则游戏读到的还是旧的那份 JSON。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

# --------------------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------------------

#: 五个兵种的显示字（与 guide_demo_kit.PIECE_SYMBOLS、PieceInfo.SYMBOLS 同一套）。
PIECE_SYMBOLS: Tuple[str, ...] = ("王", "弓", "骑", "盾", "步")

#: 文本 JSON 的格式标记与版本，游戏端会核对。
FORMAT_TAG = "neo-two-kings/guide-text"
FORMAT_VERSION = 1

#: 左栏速查卡上那句话的宽度上限（显示宽度：中文算 2）。
#: 卡片只有 160 像素宽，写长了会换行、卡片变高，六张卡就放不下了。
SHORT_MAX_WIDTH = 12

#: 条目开头不该出现的符号——界面自己会加「・」。
BULLET_PREFIXES = ("・", "·", "•", "‣", "-", "—", "*")


class TextError(Exception):
    """文案写错了（字段类型不对、棋子字不认识……）。导出时会打印成人话。"""


# --------------------------------------------------------------------------------------
# 数据模型
# --------------------------------------------------------------------------------------


@dataclass
class PieceText:
    """一种棋子的那一页：左栏卡片的一句话 + 页面开头的 tagline + 一条条正文。"""

    symbol: str
    tagline: str = ""
    short: str = ""
    points: List[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.symbol = _as_text(self.symbol, "PieceText 的 symbol")
        if self.symbol not in PIECE_SYMBOLS:
            raise TextError(
                f"棋子字「{self.symbol}」不认识，只能是 {'/'.join(PIECE_SYMBOLS)} 中的一个字"
                "（要用棋盘上那个显示字，PieceInfo.SYMBOLS 里那一套）"
            )
        where = f"「{self.symbol}」"
        self.tagline = _as_text(self.tagline, f"{where}的 tagline")
        self.short = _as_text(self.short, f"{where}的 short")
        self.points = _as_points(self.points, f"{where}的 points")

    def to_json(self) -> Dict[str, Any]:
        return {
            "symbol": self.symbol,
            "short": self.short,
            "tagline": self.tagline,
            "points": list(self.points),
        }


@dataclass
class GuideText:
    """整份指南的纯文本：怎么玩 + 每种棋子一页 + 容易搞错的点。"""

    intro_title: str = ""
    intro_points: List[str] = field(default_factory=list)
    #: 左栏「怎么玩」卡上的大字（正好一个字）与一句话。
    intro_card_glyph: str = ""
    intro_card_short: str = ""
    #: 左栏里棋子卡上方的小标题。
    pieces_title: str = ""
    pieces: List[PieceText] = field(default_factory=list)
    outro_title: str = ""
    outro_points: List[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.intro_title = _as_text(self.intro_title, "intro_title")
        self.intro_points = _as_points(self.intro_points, "intro_points")
        self.intro_card_glyph = _as_text(self.intro_card_glyph, "intro_card_glyph")
        self.intro_card_short = _as_text(self.intro_card_short, "intro_card_short")
        self.pieces_title = _as_text(self.pieces_title, "pieces_title")
        self.outro_title = _as_text(self.outro_title, "outro_title")
        self.outro_points = _as_points(self.outro_points, "outro_points")

        prepared: List[PieceText] = []
        for index, piece in enumerate(self.pieces):
            if not isinstance(piece, PieceText):
                raise TextError(
                    f"pieces[{index}] 要写成 PieceText(symbol=\"王\", …)，收到 {piece!r}"
                )
            prepared.append(piece)
        self.pieces = prepared

    def piece(self, symbol: str) -> Optional[PieceText]:
        """按显示字取某一页；没有这一页时返回 None。"""
        for piece in self.pieces:
            if piece.symbol == symbol:
                return piece
        return None

    def to_json(self) -> Dict[str, Any]:
        return {
            "intro_title": self.intro_title,
            "intro_points": list(self.intro_points),
            "intro_card_glyph": self.intro_card_glyph,
            "intro_card_short": self.intro_card_short,
            "pieces_title": self.pieces_title,
            "pieces": [piece.to_json() for piece in self.pieces],
            "outro_title": self.outro_title,
            "outro_points": list(self.outro_points),
        }


def _as_text(value: Any, where: str) -> str:
    if value is None:
        raise TextError(f"{where} 不能是 None（空着也要写 \"\"）")
    if isinstance(value, (list, tuple, dict, set)):
        raise TextError(f"{where} 要写成一句话，收到 {value!r}")
    return str(value)


def _as_points(values: Any, where: str) -> List[str]:
    if values is None:
        raise TextError(f"{where} 不能是 None；没有正文时写 []")
    if isinstance(values, str):
        raise TextError(
            f"{where} 要写成字符串列表（一条一句），收到一个字符串 {values!r}"
            "——想只写一条就写成 [\"…\"]"
        )
    if not isinstance(values, (list, tuple)):
        raise TextError(f"{where} 要写成字符串列表（一条一句），收到 {values!r}")
    out: List[str] = []
    for index, item in enumerate(values):
        if item is None:
            raise TextError(f"{where}[{index}] 不能是 None（空条目要么删掉、要么写点东西）")
        out.append(str(item))
    return out


# --------------------------------------------------------------------------------------
# 校验
# --------------------------------------------------------------------------------------


def validate(text: GuideText) -> List[str]:
    """返回所有问题（空列表 = 全部通过）。有问题时导出会被拒绝、一行都不写。"""
    problems: List[str] = []

    if not str(text.intro_title).strip():
        problems.append("「怎么玩」那一页的标题（intro_title）是空的")
    if len(str(text.intro_card_glyph)) != 1:
        problems.append(
            f"左栏「怎么玩」卡上的大字（intro_card_glyph）必须正好是一个字，"
            f"现在是「{text.intro_card_glyph}」"
        )
    if not str(text.intro_card_short).strip():
        problems.append("左栏「怎么玩」卡上的那句话（intro_card_short）是空的")
    _validate_points(problems, "「怎么玩」", text.intro_points)

    if not str(text.pieces_title).strip():
        problems.append("左栏里棋子卡上方的小标题（pieces_title）是空的")

    symbols = [piece.symbol for piece in text.pieces]
    missing = [symbol for symbol in PIECE_SYMBOLS if symbol not in symbols]
    if missing:
        problems.append(
            f"缺这些棋子的说明：{'、'.join(missing)}"
            "（每一种都要有一页——指南左栏的速查卡就是按这个生成的）"
        )
    duplicated = [symbol for symbol in PIECE_SYMBOLS if symbols.count(symbol) > 1]
    if duplicated:
        problems.append(f"这些棋子写了两遍：{'、'.join(duplicated)}")
    for piece in text.pieces:
        where = f"「{piece.symbol}」"
        if not str(piece.tagline).strip():
            problems.append(f"{where}没写 tagline（这一页开头那一句）")
        if not str(piece.short).strip():
            problems.append(f"{where}没写 short（左栏速查卡上那句话）")
        _validate_points(problems, where, piece.points)

    if not str(text.outro_title).strip():
        problems.append("「几个容易搞错的点」那一页的标题（outro_title）是空的")
    _validate_points(problems, "「几个容易搞错的点」", text.outro_points)

    return problems


def _validate_points(problems: List[str], where: str, points: Sequence[str]) -> None:
    if not points:
        problems.append(f"{where}一条正文都没有（至少要有一条）")
        return
    for index, item in enumerate(points):
        if not str(item).strip():
            problems.append(f"{where}的第 {index + 1} 条是空的")


def warnings(text: GuideText) -> List[str]:
    """不拦保存、但值得看一眼的问题。"""
    notes: List[str] = []

    if _display_width(text.intro_card_short) > SHORT_MAX_WIDTH:
        notes.append(
            f"「怎么玩」卡的 short「{text.intro_card_short}」太长了"
            f"（超过 {SHORT_MAX_WIDTH // 2} 个汉字），左栏那张卡会换行、变高"
        )
    for piece in text.pieces:
        if _display_width(piece.short) > SHORT_MAX_WIDTH:
            notes.append(
                f"「{piece.symbol}」的 short「{piece.short}」太长了"
                f"（超过 {SHORT_MAX_WIDTH // 2} 个汉字），左栏那张卡会换行、变高"
            )

    pages: List[Tuple[str, Sequence[str]]] = [
        ("「怎么玩」", text.intro_points),
        *((f"「{piece.symbol}」", piece.points) for piece in text.pieces),
        ("「几个容易搞错的点」", text.outro_points),
    ]
    for where, points in pages:
        for index, item in enumerate(points):
            head = str(item).lstrip()[:1]
            if head in BULLET_PREFIXES:
                notes.append(
                    f"{where}的第 {index + 1} 条自己写了开头符号「{head}」——"
                    "界面上会再加一个「・」，把它去掉"
                )
        seen: Dict[str, int] = {}
        for index, item in enumerate(points):
            key = str(item).strip()
            if key in seen:
                notes.append(
                    f"{where}的第 {seen[key] + 1} 条与第 {index + 1} 条一模一样，多半是复制出来忘了改"
                )
            else:
                seen[key] = index
    return notes


def _display_width(text: str) -> int:
    """中文按两格算——左栏卡片的宽度是按「几个汉字」算的。"""
    return sum(2 if ord(char) > 0x2E80 else 1 for char in str(text))


# --------------------------------------------------------------------------------------
# 序列化
# --------------------------------------------------------------------------------------


def payload(text: GuideText) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "format": FORMAT_TAG,
        "version": FORMAT_VERSION,
        "generator": "tools/export_guide_text.py",
        "warning": "这个文件由 Python 工具生成，不要手改；改文案请改 tools/guide_text.py 再跑一次导出。",
    }
    data.update(text.to_json())
    return data


def dumps(text: GuideText) -> str:
    return json.dumps(payload(text), ensure_ascii=False, indent=2) + "\n"


def write(path: Union[str, Path], text: GuideText) -> bool:
    """写出 JSON；返回「内容是否真的变了」。"""
    path = Path(path)
    body = dumps(text)
    old = path.read_text(encoding="utf-8") if path.exists() else None
    if old == body:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8", newline="\n")
    return True


def summary(text: GuideText) -> List[Tuple[str, int, int]]:
    """给导出脚本打表格用：(页面, 条目数, 字数)。"""
    rows: List[Tuple[str, int, int]] = [
        (
            text.intro_title or "（怎么玩）",
            len(text.intro_points),
            len(text.intro_title) + sum(len(item) for item in text.intro_points),
        )
    ]
    for piece in text.pieces:
        rows.append(
            (
                piece.symbol,
                len(piece.points),
                len(piece.tagline) + len(piece.short) + sum(len(item) for item in piece.points),
            )
        )
    rows.append(
        (
            text.outro_title or "（易错点）",
            len(text.outro_points),
            len(text.outro_title) + sum(len(item) for item in text.outro_points),
        )
    )
    return rows
