# -*- coding: utf-8 -*-
"""指南动画编辑器的界面（Tkinter）。

打开方式：

    python tools/editor/editor.py

界面就四块：左边是**帧列表**（每帧一行），中间是**棋盘**，右边是**属性**（文字、停留时间、
这一帧的箭头），底下一条**状态栏**。

工具只有三个（`摆子` / `箭头` / `高亮`），因为一帧就是一张画：

* **摆子**：左键在格子上放当前选的棋子（先选兵种和红/绿），右键把那格擦掉。
* **箭头**：左键点起点、再左键点终点就画出一条；右键＝取消这次的起点，
  或者删掉「起点或终点落在这格」的箭头。颜色由箭头样式决定（移动/攻击/跳跃）。
* **高亮**：左键切换这一格的橙色高亮。

编辑器**完全不碰棋规**：棋子的阵营是你选的，箭头指向哪就是哪，谁死了就靠「下一帧别写它」。
"""

from __future__ import annotations

import copy
import sys
import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk
from typing import Any, Dict, List, Optional, Tuple

from editor import model
from editor.model import Doc, Point, point_of

# --------------------------------------------------------------------------------------
# 配色：和 game 那边同一套来源（guide_demo.gd 的常量、piece.gd 的 CAMP_COLORS）
# --------------------------------------------------------------------------------------

BG = "#ffffff"
GRID_COLOR = "#d2dcf2"
ZONE_COLOR = "#fdeed4"
ZONE_BORDER = "#f0a020"
SELECT_COLOR = "#1f5fd0"
TEXT_COLOR = "#1e2141"
MUTED_COLOR = "#7a8095"
CAMP_COLORS = {"red": "#cc2f26", "green": "#1f9d4d"}
#: 箭头三种样式的颜色，与 guide_demo.gd 的 _draw_arrows 一致。
ARROW_COLORS = {"move": "#1f5fd0", "shot": "#d0402f", "hop": "#7a5cd0"}

#: 兵种显示字（与 PieceInfo.SYMBOLS 一致）。
SYMBOLS = ("王", "弓", "骑", "盾", "步")

TOOLS = [("piece", "摆子"), ("arrow", "箭头"), ("highlight", "高亮")]
TOOL_HINTS = {
    "piece": "左键放棋子、右键擦掉（先选兵种与红/绿）",
    "arrow": "左键点起点、再点终点画箭头；右键取消起点或删掉碰着这格的箭头",
    "highlight": "左键切换这一格的橙色高亮",
}

HELP = (
    "左键＝按当前工具操作，右键＝擦 / 删 / 取消　·　"
    "Ctrl+S 保存 · Ctrl+Z 撤销 · Ctrl+Y 重做 · Ctrl+R 重新载入 · Del 擦掉选中格里的棋子"
)

PROPS_WIDTH = 320
LEFT_WIDTH = 250


def _pick_font(root: tk.Misc, prefers: List[str], fallback: str, size: int) -> tkfont.Font:
    """挑一个系统里真有的中文字体（换机器时别变成方块）。"""
    available = set(tkfont.families(root))
    for name in prefers:
        if name in available:
            return tkfont.Font(root=root, family=name, size=size)
    return tkfont.Font(root=root, family=fallback, size=size)


def style_label(style: str) -> str:
    """箭头样式的中文名（与 guide_demo_kit 里的一致）。"""
    return str(model.kit.ARROW_STYLE_LABELS.get(style, style))


class EditorApp:
    """整个编辑器：持有 Doc（数据）+ 一堆控件。"""

    def __init__(self, root: tk.Tk, doc: Doc) -> None:
        self.root = root
        self.doc = doc
        self.symbol = doc.symbols()[0]
        self.demo_index = 0
        self.frame_index = 0
        self.tool = "piece"
        self.palette_symbol = "王"
        self.palette_camp = "red"
        self.arrow_style = "move"
        self.selected_cell: Optional[Point] = None
        #: 画箭头时先点的那个起点
        self.pending_from: Optional[Point] = None
        self.dirty = False
        self._rebuilding = False
        #: 所有 Tk 变量都要留一个引用：被 GC 掉的话控件会发疯（实测踩过一次）
        self._vars: List[tk.Variable] = []

        self.body_font = _pick_font(root, ["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"], "TkDefaultFont", 10)
        self.glyph_font = _pick_font(root, ["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"], "TkDefaultFont", 20)
        self.small_font = _pick_font(root, ["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"], "TkDefaultFont", 9)

        root.title("NeoTwoKings 指南动画编辑器")
        root.geometry("1240x780")
        root.minsize(1150, 620)
        root.configure(bg=BG)
        self._build_style()
        self._build_ui()
        self._bind_keys()
        self._refresh_all()
        root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ------------------------------------------------------------------ 界面骨架

    def _build_style(self) -> None:
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:  # pragma: no cover
            pass
        style.configure(".", font=self.body_font)
        style.configure("TButton", padding=(8, 4))
        style.configure("Tool.TButton", padding=(6, 3))
        style.configure("ToolOn.TButton", padding=(6, 3), background="#d6e4ff")
        style.configure("Head.TLabel", font=self.body_font, foreground=TEXT_COLOR)
        style.configure("Muted.TLabel", foreground=MUTED_COLOR, font=self.small_font)

    def _build_ui(self) -> None:
        # 顶部两行：一行选兵种与动画，一行放命令。刻意不排成一行——一行按钮的请求宽度
        # 加起来会把窗口撑到屏幕外（第一版就是这么把右栏挤没的）。
        top = ttk.Frame(self.root, padding=(10, 8, 10, 2))
        top.pack(fill="x")
        ttk.Label(top, text="兵种", style="Head.TLabel").pack(side="left")
        self.piece_buttons: Dict[str, ttk.Button] = {}
        for symbol in self.doc.symbols():
            button = ttk.Button(top, text=symbol, width=3, command=lambda s=symbol: self.select_symbol(s))
            button.pack(side="left", padx=2)
            self.piece_buttons[symbol] = button
        ttk.Separator(top, orient="vertical").pack(side="left", fill="y", padx=8)
        ttk.Label(top, text="动画", style="Head.TLabel").pack(side="left")
        ttk.Button(top, text="◀", width=3, command=lambda: self.step_demo(-1)).pack(side="left", padx=2)
        self.demo_label = ttk.Label(top, text="", style="Head.TLabel", width=10, anchor="center")
        self.demo_label.pack(side="left")
        ttk.Button(top, text="▶", width=3, command=lambda: self.step_demo(1)).pack(side="left", padx=2)
        ttk.Button(top, text="新动画", command=self.add_demo).pack(side="left", padx=2)
        ttk.Button(top, text="删本段", command=self.del_demo).pack(side="left", padx=2)
        self.summary_label = ttk.Label(top, text="", style="Muted.TLabel")
        self.summary_label.pack(side="left", padx=12)

        commands = ttk.Frame(self.root, padding=(10, 0, 10, 4))
        commands.pack(fill="x")
        for text, command in [("撤销", self.undo), ("重做", self.redo),
                              ("重新载入", self.reload), ("校验", self.validate_now)]:
            ttk.Button(commands, text=text, command=command).pack(side="left", padx=2)
        ttk.Button(commands, text="保存到 Python", command=self.save).pack(side="left", padx=8)
        ttk.Label(commands, text="保存会写回 tools/demos/*.py 并刷新 data/guide_demos.json",
                  style="Muted.TLabel").pack(side="left", padx=6)

        middle = ttk.Frame(self.root)
        middle.pack(fill="both", expand=True, padx=10, pady=6)
        middle.columnconfigure(0, weight=0, minsize=LEFT_WIDTH)
        middle.columnconfigure(1, weight=1, minsize=460)
        middle.columnconfigure(2, weight=0, minsize=PROPS_WIDTH + 20)
        middle.rowconfigure(0, weight=1)

        # --- 左：帧列表 ---
        left = ttk.Frame(middle)
        left.grid(row=0, column=0, sticky="nsew")
        ttk.Label(left, text="帧", style="Head.TLabel").pack(anchor="w")
        list_wrap = ttk.Frame(left)
        list_wrap.pack(fill="both", expand=True)
        self.frame_list = tk.Listbox(list_wrap, font=self.body_font, activestyle="none",
                                     selectmode="browse", exportselection=False, width=30)
        scroll = ttk.Scrollbar(list_wrap, orient="vertical", command=self.frame_list.yview)
        self.frame_list.configure(yscrollcommand=scroll.set)
        self.frame_list.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")
        self.frame_list.bind("<<ListboxSelect>>", self.on_frame_select)

        buttons = ttk.Frame(left)
        buttons.pack(fill="x", pady=4)
        for index, (text, command) in enumerate([
            ("+帧", self.add_frame), ("复制帧", self.duplicate_frame), ("删除", self.delete_frame),
            ("↑ 上移", lambda: self.move_frame(-1)), ("↓ 下移", lambda: self.move_frame(1)),
        ]):
            ttk.Button(buttons, text=text, style="Tool.TButton", command=command).grid(
                row=index // 3, column=index % 3, padx=1, pady=1, sticky="ew")

        # --- 中：棋盘 ---
        center = ttk.Frame(middle)
        center.grid(row=0, column=1, sticky="nsew", padx=8)
        # 控件排成两行小格子：一行排满会把窗口顶宽（右栏就被挤到屏幕外）。
        control = ttk.Frame(center)
        control.pack(fill="x")
        tools_box = ttk.LabelFrame(control, text="工具", padding=(6, 2))
        tools_box.grid(row=0, column=0, sticky="nw")
        self.tool_buttons: Dict[str, ttk.Button] = {}
        for key, label in TOOLS:
            button = ttk.Button(tools_box, text=label, width=6, style="Tool.TButton",
                                command=lambda k=key: self.select_tool(k))
            button.pack(side="left", padx=1)
            self.tool_buttons[key] = button

        palette_box = ttk.LabelFrame(control, text="棋子", padding=(6, 2))
        palette_box.grid(row=0, column=1, sticky="nw", padx=6)
        self.glyph_buttons: Dict[str, ttk.Button] = {}
        for index, symbol in enumerate(SYMBOLS):
            button = ttk.Button(palette_box, text=symbol, width=3, command=lambda s=symbol: self.select_glyph(s))
            button.grid(row=0, column=index, padx=1, pady=1)
            self.glyph_buttons[symbol] = button
        self.camp_buttons: Dict[str, ttk.Button] = {}
        for index, (key, label) in enumerate([("red", "红"), ("green", "绿")]):
            button = ttk.Button(palette_box, text=label, width=6, command=lambda k=key: self.select_camp(k))
            button.grid(row=1, column=index, padx=1, pady=1)
            self.camp_buttons[key] = button

        arrow_box = ttk.LabelFrame(control, text="箭头", padding=(6, 2))
        arrow_box.grid(row=1, column=0, columnspan=2, sticky="nw", pady=(4, 0))
        self.arrow_buttons: Dict[str, ttk.Button] = {}
        for index, style in enumerate(("move", "shot", "hop")):
            button = ttk.Button(arrow_box, text=style_label(style), width=7, style="Tool.TButton",
                                command=lambda s=style: self.select_arrow_style(s))
            button.pack(side="left", padx=1)
            self.arrow_buttons[style] = button

        self.canvas = tk.Canvas(center, bg=BG, highlightthickness=1, highlightbackground="#c9d2e4",
                                width=400, height=400)
        self.canvas.pack(fill="both", expand=True, pady=6)
        self.canvas.bind("<Button-1>", lambda event: self.on_board_click(event, primary=True))
        self.canvas.bind("<Button-3>", lambda event: self.on_board_click(event, primary=False))
        self.canvas.bind("<Configure>", lambda event: self.draw_board())

        # --- 右：属性 ---
        right_panel = ttk.Frame(middle)
        right_panel.grid(row=0, column=2, sticky="nsew")
        ttk.Label(right_panel, text="属性", style="Head.TLabel").pack(anchor="w")
        outer = ttk.Frame(right_panel)
        outer.pack(fill="both", expand=True)
        self.props_canvas = tk.Canvas(outer, width=PROPS_WIDTH, highlightthickness=0, bg=BG)
        props_scroll = ttk.Scrollbar(outer, orient="vertical", command=self.props_canvas.yview)
        self.props_canvas.configure(yscrollcommand=props_scroll.set)
        self.props_canvas.pack(side="left", fill="both", expand=True)
        props_scroll.pack(side="left", fill="y")
        self.props = ttk.Frame(self.props_canvas)
        self.props_canvas.create_window((0, 0), window=self.props, anchor="nw", width=PROPS_WIDTH)
        self.props.columnconfigure(0, weight=1)
        self.props.bind("<Configure>",
                        lambda event: self.props_canvas.configure(scrollregion=self.props_canvas.bbox("all")))

        # --- 底：状态栏 ---
        bottom = ttk.Frame(self.root, padding=(10, 0, 10, 8))
        bottom.pack(fill="x")
        self.status = ttk.Label(bottom, text="", style="Muted.TLabel", anchor="w", justify="left", wraplength=940)
        self.status.pack(fill="x")
        ttk.Label(bottom, text=HELP, style="Muted.TLabel", anchor="w", justify="left",
                  wraplength=940).pack(fill="x")

    def _bind_keys(self) -> None:
        self.root.bind("<Control-s>", lambda event: self.save())
        self.root.bind("<Control-z>", lambda event: self.undo())
        self.root.bind("<Control-y>", lambda event: self.redo())
        self.root.bind("<Control-r>", lambda event: self.reload())
        self.root.bind("<Delete>", lambda event: self.delete_cell_content())

    # ------------------------------------------------------------------ 当前选中

    def _demo(self) -> Optional[model.kit.Demo]:
        demos = self.doc.demos.get(self.symbol, [])
        if not demos:
            return None
        self.demo_index = max(0, min(self.demo_index, len(demos) - 1))
        return demos[self.demo_index]

    def _frame(self) -> Optional[model.kit.Frame]:
        demo = self._demo()
        if demo is None or not demo.frames:
            return None
        self.frame_index = max(0, min(self.frame_index, len(demo.frames) - 1))
        return demo.frames[self.frame_index]

    def _set_status(self, text: str, error: bool = False) -> None:
        self.status.configure(text=text, foreground=("#c0392b" if error else MUTED_COLOR))

    def _touch(self, *, rebuild_props: bool = False) -> None:
        """任何改动之后：刷新标题与列表、重画棋盘，必要时重建属性面板。"""
        self.dirty = True
        self._update_title()
        self.refresh_frame_list()
        self.draw_board()
        self.summary_label.configure(text=self.doc.summary())
        if rebuild_props and not self._rebuilding:
            self.refresh_props()

    def _update_title(self) -> None:
        self.root.title("NeoTwoKings 指南动画编辑器" + (" *" if self.dirty else ""))

    def _refresh_all(self) -> None:
        self.refresh_frame_list()
        self.refresh_props()
        self.draw_board()
        self.refresh_tool_buttons()
        self._update_title()
        self.summary_label.configure(text=self.doc.summary())
        self.pending_from = None

    # ------------------------------------------------------------------ 顶部选择

    def select_symbol(self, symbol: str) -> None:
        self.symbol = symbol
        self.demo_index = 0
        self.frame_index = 0
        self.selected_cell = None
        self._refresh_all()

    def step_demo(self, delta: int) -> None:
        demos = self.doc.demos.get(self.symbol, [])
        if not demos:
            return
        self.demo_index = (self.demo_index + delta) % len(demos)
        self.frame_index = 0
        self._refresh_all()

    def add_demo(self) -> None:
        self.doc.push_undo()
        current = self._demo()
        self.doc.demos.setdefault(self.symbol, []).append(model.new_demo(current.size if current else 7))
        self.demo_index = len(self.doc.demos[self.symbol]) - 1
        self.frame_index = 0
        self._touch(rebuild_props=True)

    def del_demo(self) -> None:
        demos = self.doc.demos.get(self.symbol, [])
        if len(demos) <= 1:
            self._set_status("这个兵种只剩一段动画了，不能删（每种棋子至少要有一段）", error=True)
            return
        if not messagebox.askyesno("删除动画", f"删掉「{self.symbol}」的第 {self.demo_index + 1} 段动画？"):
            return
        self.doc.push_undo()
        demos.pop(self.demo_index)
        self.demo_index = max(0, self.demo_index - 1)
        self.frame_index = 0
        self._touch(rebuild_props=True)

    # ------------------------------------------------------------------ 帧列表

    def refresh_frame_list(self) -> None:
        demo = self._demo()
        self.frame_list.delete(0, "end")
        if demo is None:
            return
        for index, frame in enumerate(demo.frames):
            self.frame_list.insert("end", self._frame_label(index, frame))
        if demo.frames:
            self.frame_list.selection_clear(0, "end")
            self.frame_list.selection_set(self.frame_index)
            self.frame_list.see(self.frame_index)

    def _frame_label(self, index: int, frame: model.kit.Frame) -> str:
        text = " ".join(str(frame.text).split())
        if len(text) > 12:
            text = text[:12] + "…"
        return f"{index + 1}. {float(frame.hold):g}s · {len(frame.pieces or {})}子 {len(frame.arrows or [])}箭 {text}"

    def on_frame_select(self, _event: Any = None) -> None:
        selection = self.frame_list.curselection()
        if not selection:
            return
        self.frame_index = int(selection[0])
        self.selected_cell = None
        self.pending_from = None
        self.refresh_props()
        self.draw_board()

    def add_frame(self) -> None:
        demo = self._demo()
        if demo is None:
            return
        self.doc.push_undo()
        # 新帧沿用当前帧的棋子与高亮（通常只差一点），箭头与文字留空重写
        demo.frames.insert(self.frame_index + 1, model.new_frame_like(self._frame()))
        self.frame_index = min(self.frame_index + 1, len(demo.frames) - 1)
        self._touch(rebuild_props=True)
        self._set_status("新的一帧已经插在后面：它沿用了上一帧的棋子，改完记得写这一帧的说明")

    def duplicate_frame(self) -> None:
        demo = self._demo()
        frame = self._frame()
        if demo is None or frame is None:
            return
        self.doc.push_undo()
        demo.frames.insert(self.frame_index + 1, copy.deepcopy(frame))
        self.frame_index = min(self.frame_index + 1, len(demo.frames) - 1)
        self._touch(rebuild_props=True)

    def delete_frame(self) -> None:
        demo = self._demo()
        if demo is None or not demo.frames:
            return
        if len(demo.frames) <= 1:
            self._set_status("一段动画至少要有一帧", error=True)
            return
        self.doc.push_undo()
        demo.frames.pop(self.frame_index)
        self.frame_index = max(0, self.frame_index - 1)
        self._touch(rebuild_props=True)

    def move_frame(self, delta: int) -> None:
        demo = self._demo()
        if demo is None:
            return
        target = self.frame_index + delta
        if not (0 <= target < len(demo.frames)):
            return
        self.doc.push_undo()
        demo.frames.insert(target, demo.frames.pop(self.frame_index))
        self.frame_index = target
        self._touch(rebuild_props=True)

    # ------------------------------------------------------------------ 工具 / 调色板

    def select_tool(self, key: str) -> None:
        self.tool = key
        self.pending_from = None
        self.refresh_tool_buttons()
        self._set_status(f"工具「{dict(TOOLS)[key]}」：{TOOL_HINTS[key]}")
        self.draw_board()

    def select_glyph(self, symbol: str) -> None:
        self.palette_symbol = symbol
        if self.tool != "piece":
            self.tool = "piece"
        self.refresh_tool_buttons()
        self._set_status(f"现在摆的是{'红' if self.palette_camp == 'red' else '绿'}{symbol}")

    def select_camp(self, camp: str) -> None:
        self.palette_camp = camp
        if self.tool != "piece":
            self.tool = "piece"
        self.refresh_tool_buttons()
        self._set_status(f"现在摆的是{'红' if camp == 'red' else '绿'}{self.palette_symbol}")

    def select_arrow_style(self, style: str) -> None:
        self.arrow_style = style
        if self.tool != "arrow":
            self.tool = "arrow"
        self.refresh_tool_buttons()
        self._set_status(f"箭头样式：{style_label(style)}")

    def refresh_tool_buttons(self) -> None:
        for key, button in self.tool_buttons.items():
            button.configure(style="ToolOn.TButton" if key == self.tool else "Tool.TButton")
        for symbol, button in self.piece_buttons.items():
            button.configure(style="ToolOn.TButton" if symbol == self.symbol else "TButton")
        for symbol, button in self.glyph_buttons.items():
            button.configure(style="ToolOn.TButton" if symbol == self.palette_symbol else "TButton")
        for camp, button in self.camp_buttons.items():
            button.configure(style="ToolOn.TButton" if camp == self.palette_camp else "TButton")
        for style, button in self.arrow_buttons.items():
            button.configure(style="ToolOn.TButton" if style == self.arrow_style else "Tool.TButton")
        self.demo_label.configure(text=f"第 {self.demo_index + 1} / {len(self.doc.demos.get(self.symbol, []))} 段")

    # ------------------------------------------------------------------ 棋盘

    def _board_size(self) -> int:
        demo = self._demo()
        return demo.size if demo is not None else 7

    def _board_geometry(self) -> Tuple[float, float, float]:
        size = self._board_size()
        width = max(self.canvas.winfo_width(), 10)
        height = max(self.canvas.winfo_height(), 10)
        cell = max(min((width - 24) / size, (height - 24) / size), 8.0)
        return cell, (width - cell * size) / 2, (height - cell * size) / 2

    def _cell_center(self, cell: Point) -> Tuple[float, float]:
        size_cell, ox, oy = self._board_geometry()
        return ox + (cell[0] + 0.5) * size_cell, oy + (cell[1] + 0.5) * size_cell

    def _event_to_cell(self, event: Any) -> Optional[Point]:
        size = self._board_size()
        size_cell, ox, oy = self._board_geometry()
        col = int((event.x - ox) // size_cell)
        row = int((event.y - oy) // size_cell)
        if 0 <= col < size and 0 <= row < size:
            return (col, row)
        return None

    def draw_board(self) -> None:
        canvas = self.canvas
        canvas.delete("all")
        frame = self._frame()
        size = self._board_size()
        cell, ox, oy = self._board_geometry()

        for i in range(size + 1):
            canvas.create_line(ox + i * cell, oy, ox + i * cell, oy + size * cell, fill=GRID_COLOR)
            canvas.create_line(ox, oy + i * cell, ox + size * cell, oy + i * cell, fill=GRID_COLOR)

        if frame is not None:
            for item in frame.highlights or []:
                point = point_of(item)
                x0, y0 = ox + point[0] * cell, oy + point[1] * cell
                canvas.create_rectangle(x0, y0, x0 + cell, y0 + cell, fill=ZONE_COLOR, outline=ZONE_BORDER, width=2)

            ordered = sorted((frame.pieces or {}).items(), key=lambda kv: (point_of(kv[0])[1], point_of(kv[0])[0]))
            for key, value in ordered:
                point = point_of(key)
                cx, cy = self._cell_center(point)
                canvas.create_text(cx, cy, text=str(value[0]),
                                   fill=CAMP_COLORS.get(str(value[1]), TEXT_COLOR),
                                   font=self.glyph_font if cell >= 26 else self.body_font)

            for item in frame.arrows or []:
                self._draw_arrow(point_of(item["from"]), point_of(item["to"]), str(item.get("style", "move")))

        if self.selected_cell is not None:
            x0, y0 = ox + self.selected_cell[0] * cell, oy + self.selected_cell[1] * cell
            canvas.create_rectangle(x0 + 1, y0 + 1, x0 + cell - 1, y0 + cell - 1, outline=SELECT_COLOR, width=2)

        if self.pending_from is not None:
            cx, cy = self._cell_center(self.pending_from)
            radius = cell * 0.42
            color = ARROW_COLORS[self.arrow_style]
            canvas.create_oval(cx - radius, cy - radius, cx + radius, cy + radius, outline=color, width=2)
            canvas.create_text(cx, cy - radius - 8, text="起点", fill=color, font=self.small_font)

    def _draw_arrow(self, start: Point, end: Point, style: str) -> None:
        x0, y0 = self._cell_center(start)
        x1, y1 = self._cell_center(end)
        cell, _, _ = self._board_geometry()
        color = ARROW_COLORS.get(style, ARROW_COLORS["move"])
        # 两端让开一点，别压住棋子字（和游戏里的画法一致）
        dx, dy = x1 - x0, y1 - y0
        length = (dx * dx + dy * dy) ** 0.5
        if length < 1e-3:
            return
        inset = min(length * 0.2, cell * 0.34)
        sx, sy = x0 + dx / length * inset, y0 + dy / length * inset
        ex, ey = x1 - dx / length * inset, y1 - dy / length * inset
        self.canvas.create_line(sx, sy, ex, ey, fill=color, width=3, arrow="last", arrowshape=(12, 14, 5))

    # ------------------------------------------------------------------ 棋盘上的编辑

    def on_board_click(self, event: Any, primary: bool) -> None:
        cell = self._event_to_cell(event)
        if cell is None:
            return
        self.selected_cell = cell
        frame = self._frame()
        if frame is None:
            self.draw_board()
            return

        if self.tool == "piece":
            self.doc.push_undo()
            if primary:
                model.set_piece(frame, cell, self.palette_symbol, self.palette_camp)
                self._set_status(f"{cell} 放上{'红' if self.palette_camp == 'red' else '绿'}{self.palette_symbol}")
            else:
                model.erase_piece(frame, cell)
                self._set_status(f"{cell} 擦掉了")
            self._touch(rebuild_props=True)
            return

        if self.tool == "highlight":
            self.doc.push_undo()
            lit = model.toggle_highlight(frame, cell)
            self._set_status(f"{cell} 的高亮：{'打开' if lit else '关掉'}")
            self._touch()
            return

        # 箭头
        if primary:
            if self.pending_from is None:
                self.pending_from = cell
                self._set_status(f"箭头的起点设在 {cell}：再点一个格子就是终点")
            else:
                start = self.pending_from
                self.pending_from = None
                if start == cell:
                    self._set_status("起点和终点是同一格，这次不画了")
                else:
                    self.doc.push_undo()
                    model.add_arrow(frame, start, cell, self.arrow_style)
                    self._set_status(f"画了箭头 {start} → {cell}（{style_label(self.arrow_style)}）")
                    self._touch(rebuild_props=True)
                    return
        else:
            if self.pending_from is not None:
                self.pending_from = None
                self._set_status("取消了这次的起点")
            else:
                self.doc.push_undo()
                removed = model.remove_arrows_touching(frame, cell)
                self._set_status(f"{cell} 上删掉了 {removed} 条箭头" if removed else f"{cell} 上没有箭头")
                self._touch(rebuild_props=True)
                return
        self.draw_board()

    def delete_cell_content(self) -> None:
        frame = self._frame()
        if frame is None or self.selected_cell is None:
            return
        self.doc.push_undo()
        model.erase_piece(frame, self.selected_cell)
        self._set_status(f"{self.selected_cell} 的棋子擦掉了")
        self._touch(rebuild_props=True)

    # ------------------------------------------------------------------ 属性面板

    def refresh_props(self) -> None:
        self._rebuilding = True
        for child in self.props.winfo_children():
            child.destroy()
        self._vars.clear()
        demo = self._demo()
        if demo is None:
            self._rebuilding = False
            return
        row = self._demo_props(demo, 0)
        if self._frame() is not None:
            row = self._frame_props(demo, row)
        self._rebuilding = False

    # --- 表单控件（单列：字段名一行、控件一行占满宽度）---

    def _label(self, row: int, text: str, *, muted: bool = False) -> int:
        ttk.Label(self.props, text=text, style=("Muted.TLabel" if muted else "Head.TLabel"),
                  wraplength=PROPS_WIDTH - 28, justify="left").grid(row=row, column=0, sticky="w", pady=(3, 0))
        return row + 1

    def _hint(self, row: int, text: str) -> int:
        return self._label(row, text, muted=True)

    def _section(self, row: int, title: str) -> int:
        ttk.Separator(self.props).grid(row=row, column=0, sticky="ew", pady=(10, 4))
        ttk.Label(self.props, text=title, style="Head.TLabel").grid(row=row + 1, column=0, sticky="w")
        return row + 2

    def _text_row(self, row: int, label: str, value: str, setter: Any, *, height: int = 3) -> int:
        row = self._label(row, label)
        # width=1：tk.Text 默认要 80 列（约 640px），不改的话属性栏的请求宽度会爆炸
        widget = tk.Text(self.props, height=height, width=1, wrap="word", font=self.body_font,
                         relief="solid", borderwidth=1)
        widget.insert("1.0", value)
        widget.edit_modified(False)
        widget.grid(row=row, column=0, sticky="ew", pady=(0, 4))

        def on_modified(_event: Any = None) -> None:
            if not widget.edit_modified():
                return
            widget.edit_modified(False)
            setter(widget.get("1.0", "end-1c"))
            self.dirty = True
            self._update_title()
            self.refresh_frame_list()
            self.draw_board()

        widget.bind("<<Modified>>", on_modified)
        return row + 1

    def _entry_row(self, row: int, label: str, value: str, setter: Any) -> int:
        row = self._label(row, label)
        variable = tk.StringVar(value=value)
        self._vars.append(variable)  # 必须留引用，见 __init__ 的说明
        entry = ttk.Entry(self.props, textvariable=variable, width=1, font=self.body_font)
        entry.grid(row=row, column=0, sticky="ew", pady=(0, 4))
        entry.bind("<FocusOut>", lambda event: setter(variable.get()))
        entry.bind("<Return>", lambda event: setter(variable.get()))
        return row + 1

    def _spin_row(self, row: int, label: str, value: int, low: int, high: int, setter: Any) -> int:
        row = self._label(row, label)
        variable = tk.IntVar(value=int(value))
        self._vars.append(variable)
        spin = ttk.Spinbox(self.props, from_=low, to=high, textvariable=variable, width=6,
                           command=lambda: setter(variable.get()))
        spin.grid(row=row, column=0, sticky="w")
        spin.bind("<FocusOut>", lambda event: setter(variable.get()))
        return row + 1

    def _button_row(self, row: int, label: str, text: str, command: Any) -> int:
        row = self._hint(row, label)
        ttk.Button(self.props, text=text, style="Tool.TButton", command=command).grid(
            row=row, column=0, sticky="w", pady=(0, 4))
        return row + 1

    # --- 两段属性 ---

    def _demo_props(self, demo: Any, row: int) -> int:
        row = self._section(row, "这段动画")
        row = self._text_row(row, "标题 caption", demo.caption,
                             lambda value: self._set_caption(demo, value), height=2)
        row = self._spin_row(row, "棋盘边长 size", demo.size, 2, 16, lambda value: self._set_size(demo, int(value)))
        return row

    def _set_caption(self, demo: Any, value: str) -> None:
        demo.caption = value

    def _set_size(self, demo: Any, size: int) -> None:
        try:
            model.set_size(demo, size)
        except ValueError as exc:
            self._set_status(str(exc), error=True)
            return
        self.dirty = True
        self._update_title()
        self.draw_board()

    def _frame_props(self, demo: Any, row: int) -> int:
        frame = self._frame()
        row = self._section(row, f"第 {self.frame_index + 1} 帧（共 {len(demo.frames)} 帧）")
        row = self._text_row(row, "说明 text（棋盘下方那句话）", frame.text,
                             lambda value: self._set_text(frame, value), height=3)
        row = self._entry_row(row, "停留 hold（秒）", f"{float(frame.hold):g}",
                              lambda value: self._set_hold(frame, value))
        row = self._hint(row, f"这一帧画了 {len(frame.pieces or {})} 枚棋子、"
                              f"{len(frame.highlights or [])} 个高亮格、{len(frame.arrows or [])} 条箭头")
        row = self._hint(row, "棋子与高亮都在棋盘上点：上面选工具，右键＝擦 / 删 / 取消")

        if frame.arrows:
            row = self._label(row, "这一帧的箭头（点右边的「删」去掉）")
            for index, item in enumerate(frame.arrows):
                start, end = point_of(item["from"]), point_of(item["to"])
                text = f"{start} → {end}　{style_label(str(item.get('style', 'move')))}"
                ttk.Label(self.props, text=text, style="Muted.TLabel",
                          wraplength=PROPS_WIDTH - 80, justify="left").grid(row=row, column=0, sticky="w")
                ttk.Button(self.props, text="删", width=3, style="Tool.TButton",
                           command=lambda i=index: self._remove_arrow(frame, i)).grid(row=row, column=0, sticky="e")
                row += 1
        return row

    def _set_text(self, frame: Any, value: str) -> None:
        frame.text = value

    def _set_hold(self, frame: Any, value: str) -> None:
        try:
            number = float(value)
        except ValueError:
            self._set_status(f"停留时间要写数字，收到「{value}」", error=True)
            return
        if number <= 0:
            self._set_status("停留时间必须大于 0（不然这一帧一闪而过、等于没有）", error=True)
            return
        frame.hold = number
        self.dirty = True
        self._update_title()
        self.refresh_frame_list()
        self.summary_label.configure(text=self.doc.summary())

    def _remove_arrow(self, frame: Any, index: int) -> None:
        self.doc.push_undo()
        model.remove_arrow_at(frame, index)
        self._set_status("删掉了一条箭头")
        self._touch(rebuild_props=True)

    # ------------------------------------------------------------------ 命令

    def save(self) -> None:
        try:
            notes = self.doc.save()
        except ValueError as exc:
            self._set_status(str(exc), error=True)
            messagebox.showerror("还存不了", str(exc))
            return
        self.dirty = False
        self._update_title()
        self._refresh_all()
        self._set_status("；".join(notes) + "　→　回 Godot 里打开指南就能看到")

    def validate_now(self) -> None:
        problems = self.doc.problems()
        if problems:
            tail = f"（共 {len(problems)} 处）" if len(problems) > 3 else ""
            self._set_status("；".join(problems[:3]) + tail, error=True)
            return
        notes = self.doc.warnings()
        if notes:
            self._set_status("校验通过；" + "；".join(notes[:2]))
        else:
            self._set_status(f"校验通过：{self.doc.summary()}")

    def reload(self) -> None:
        if self.dirty and not messagebox.askyesno("重新载入", "有未保存的改动，确定丢掉并重新载入？"):
            return
        self.doc.reload()
        self.dirty = False
        self.frame_index = 0
        self.selected_cell = None
        self._refresh_all()

    def undo(self) -> None:
        if self.doc.undo():
            self.dirty = True
            self._refresh_all()
        else:
            self._set_status("没有可撤销的了")

    def redo(self) -> None:
        if self.doc.redo():
            self.dirty = True
            self._refresh_all()
        else:
            self._set_status("没有可重做的了")

    def on_close(self) -> None:
        if self.dirty and not messagebox.askyesno("退出", "有未保存的改动，确定退出？"):
            return
        self.root.destroy()


def run() -> int:
    doc = Doc()
    root = tk.Tk()
    EditorApp(root, doc)
    root.mainloop()
    return 0
