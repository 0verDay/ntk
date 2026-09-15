# -*- coding: utf-8 -*-
"""指南「文字」页签的界面（Tkinter）：左边选页，右边改这一页的字段与一条条正文。

它是 `tools/editor/editor.py` 里那个 Notebook 的第二个页签（第一个是动画）。
和动画那边一样：**只有点保存才写磁盘**（写 `tools/guide_text.py` 并刷新
`neo-two-kings/data/guide_text.json`）。

界面分三块：

* 顶上一条命令（撤销 / 重做 / 重新载入 / 校验 / 保存到 Python）；
* 左边列出全部页面（怎么玩 → 小标题 → 五种棋子 → 容易搞错的点）；
* 右边是这一页的字段（标题、左栏卡片上的那句话……），
  底下一大块是**一条条的正文**：左列选第几条，右边改那一条的文字。

改一个字就会同步进内存里的那份数据（不用点「应用」），但撤销栈是**按焦点分组**的：
点进某个框之后第一次真的改动，才会把「改之前」的那一份压进撤销栈——
所以一次 Ctrl+Z 退掉的是你在那个框里连着敲的一串字，而不是一个字符。
"""

from __future__ import annotations

import tkinter as tk
from tkinter import messagebox, ttk
from tkinter import font as tkfont
from typing import Any, Callable, List

from editor import text_model
from editor.text_model import TextDoc

#: 左边页面列表的宽度。
LEFT_WIDTH = 230
#: 条目列表里每行显示多少个字（长了会撑宽左列）。
POINT_ROW_CHARS = 18

#: 新建条目时先写一句占位（校验要求每条都非空，省得一建出来就是红的）。
PLACEHOLDER_POINT = "（这一条写什么）"


class TextPane:
    """「文字」页签：持有 TextDoc（数据）+ 一堆控件。"""

    def __init__(
        self,
        parent: tk.Misc,
        doc: TextDoc,
        set_status: Callable[..., None],
        on_change: Callable[[], None],
        body_font: tkfont.Font,
        glyph_font: tkfont.Font,
        small_font: tkfont.Font,
    ) -> None:
        self.parent = parent
        self.doc = doc
        self.set_status = set_status
        self.on_change = on_change
        self.body_font = body_font
        self.glyph_font = glyph_font
        self.small_font = small_font

        self.page: str = text_model.INTRO
        self.point_index = 0
        self.dirty = False
        #: 正在程序化地填控件（这时别把 <<Modified>> / <<ListboxSelect>> 当成用户改动）
        self._syncing = False
        #: 这一次焦点里有没有压过撤销快照（见文件开头）
        self._undo_pushed = False
        #: Tk 变量都要留引用，被 GC 掉控件会发疯（和动画那边同一个坑）
        self._vars: List[tk.Variable] = []

        self._build()
        self.refresh()

    # ------------------------------------------------------------------ 骨架

    def _build(self) -> None:
        outer = ttk.Frame(self.parent, padding=(10, 8, 10, 4))
        outer.pack(fill="both", expand=True)

        commands = ttk.Frame(outer)
        commands.pack(fill="x")
        for text, command in [("撤销", self.undo), ("重做", self.redo),
                              ("重新载入", self.reload), ("校验", self.validate_now)]:
            ttk.Button(commands, text=text, command=command).pack(side="left", padx=2)
        ttk.Button(commands, text="保存到 Python", command=self.save).pack(side="left", padx=8)
        ttk.Label(commands, text="保存会写回 tools/guide_text.py 并刷新 data/guide_text.json",
                  style="Muted.TLabel").pack(side="left", padx=6)

        body = ttk.Frame(outer)
        body.pack(fill="both", expand=True, pady=(6, 0))
        body.columnconfigure(0, weight=0, minsize=LEFT_WIDTH)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        # --- 左：页面列表 ---
        left = ttk.Frame(body)
        left.grid(row=0, column=0, sticky="nsew")
        ttk.Label(left, text="页面", style="Head.TLabel").pack(anchor="w")
        self.page_list = tk.Listbox(left, font=self.body_font, activestyle="none",
                                    selectmode="browse", exportselection=False, width=26)
        self.page_list.pack(fill="both", expand=True, pady=(2, 4))
        self.page_list.bind("<<ListboxSelect>>", self.on_page_select)
        ttk.Label(left, text="这里就是指南左栏的顺序；保存后游戏里跟着变。",
                  style="Muted.TLabel", wraplength=LEFT_WIDTH - 12, justify="left").pack(anchor="w")

        # --- 右：这一页 ---
        right = ttk.Frame(body)
        right.grid(row=0, column=1, sticky="nsew", padx=(10, 0))
        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)

        self.form = ttk.Frame(right)
        self.form.grid(row=0, column=0, sticky="ew")
        self.form.columnconfigure(1, weight=1)

        self.points_box = ttk.LabelFrame(
            right, text="这一页的正文（一条一句；界面上会自动在开头加「・」）", padding=(8, 4)
        )
        self.points_box.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        self.points_box.columnconfigure(0, weight=0, minsize=210)
        self.points_box.columnconfigure(1, weight=1)
        self.points_box.rowconfigure(1, weight=1)

        buttons = ttk.Frame(self.points_box)
        buttons.grid(row=0, column=0, sticky="w", pady=(0, 3))
        for text, command in [("＋新增", self.add_point), ("删除", self.remove_point),
                              ("↑ 上移", lambda: self.move_point(-1)), ("↓ 下移", lambda: self.move_point(1))]:
            ttk.Button(buttons, text=text, style="Tool.TButton", command=command).pack(side="left", padx=1)
        self.point_hint = ttk.Label(self.points_box, text="", style="Muted.TLabel")
        self.point_hint.grid(row=0, column=1, sticky="w", padx=(8, 0))

        list_wrap = ttk.Frame(self.points_box)
        list_wrap.grid(row=1, column=0, sticky="nsew")
        self.point_list = tk.Listbox(list_wrap, font=self.body_font, activestyle="none",
                                     selectmode="browse", exportselection=False, width=24)
        point_scroll = ttk.Scrollbar(list_wrap, orient="vertical", command=self.point_list.yview)
        self.point_list.configure(yscrollcommand=point_scroll.set)
        self.point_list.pack(side="left", fill="both", expand=True)
        point_scroll.pack(side="left", fill="y")
        self.point_list.bind("<<ListboxSelect>>", self.on_point_select)

        text_wrap = ttk.Frame(self.points_box)
        text_wrap.grid(row=1, column=1, sticky="nsew", padx=(8, 0))
        # width=1：tk.Text 默认要 80 列（约 640px），不改会把窗口撑宽
        self.point_text = tk.Text(text_wrap, height=12, width=1, wrap="word", font=self.body_font,
                                  relief="solid", borderwidth=1)
        text_scroll = ttk.Scrollbar(text_wrap, orient="vertical", command=self.point_text.yview)
        self.point_text.configure(yscrollcommand=text_scroll.set)
        self.point_text.pack(side="left", fill="both", expand=True)
        text_scroll.pack(side="left", fill="y")
        self.point_text.bind("<<Modified>>", self.on_point_modified)
        self.point_text.bind("<FocusIn>", lambda event: self._reset_undo_once())

    # ------------------------------------------------------------------ 刷新

    def refresh(self) -> None:
        """整块重建（换页、撤销、重新载入、保存之后都走这里）。"""
        self._refresh_pages()
        self._refresh_form()

    def _refresh_pages(self) -> None:
        labels = [text_model.page_label(self.doc.text, page) for page in text_model.pages()]
        self._syncing = True
        self.page_list.delete(0, "end")
        for label in labels:
            self.page_list.insert("end", label)
        index = text_model.pages().index(self.page)
        self.page_list.selection_clear(0, "end")
        self.page_list.selection_set(index)
        self.page_list.see(index)
        self._syncing = False

    def _refresh_page_row(self, page: str) -> None:
        """只改左栏那一行（标题改了要立刻看得见），别动选中态。"""
        index = text_model.pages().index(page)
        self._syncing = True
        self.page_list.delete(index)
        self.page_list.insert(index, text_model.page_label(self.doc.text, page))
        self.page_list.selection_clear(0, "end")
        self.page_list.selection_set(index)
        self._syncing = False

    def _refresh_form(self) -> None:
        self._syncing = True
        for child in self.form.winfo_children():
            child.destroy()
        self._vars.clear()

        kind = text_model.page_kind(self.page)
        row = 0
        if kind == "intro":
            row = self._entry(row, "这一页的标题", self.doc.text.intro_title,
                              lambda value: setattr(self.doc.text, "intro_title", value), refresh_row=True)
            row = self._entry(row, "左栏卡片的大字（一个字）", self.doc.text.intro_card_glyph,
                              lambda value: setattr(self.doc.text, "intro_card_glyph", value))
            row = self._entry(row, "左栏卡片的一句话", self.doc.text.intro_card_short,
                              lambda value: setattr(self.doc.text, "intro_card_short", value))
        elif kind == "heading":
            row = self._entry(row, "小标题（左栏里棋子卡上方那行）", self.doc.text.pieces_title,
                              lambda value: setattr(self.doc.text, "pieces_title", value))
            ttk.Label(self.form, text="这一页只是一行小标题，没有正文。", style="Muted.TLabel").grid(
                row=row, column=0, columnspan=2, sticky="w", pady=(6, 0))
        elif kind == "outro":
            row = self._entry(row, "这一页的标题", self.doc.text.outro_title,
                              lambda value: setattr(self.doc.text, "outro_title", value), refresh_row=True)
        else:
            piece = text_model.piece_of(self.doc.text, self.page)
            if piece is not None:
                ttk.Label(self.form, text="棋子", style="Head.TLabel").grid(row=row, column=0, sticky="w", pady=3)
                ttk.Label(self.form, text=f"{piece.symbol}（显示字取自 PieceInfo.SYMBOLS，改不了）",
                          style="Muted.TLabel").grid(row=row, column=1, sticky="w", pady=3)
                row += 1
                row = self._entry(row, "左栏卡片的一句话（越短越好）", piece.short,
                                  lambda value: setattr(piece, "short", value))
                row = self._entry(row, "这一页开头那一句 tagline", piece.tagline,
                                  lambda value: setattr(piece, "tagline", value))
        self._syncing = False

        if kind == "heading":
            # 小标题没有正文，把条目区整个藏掉（不藏会让人以为「这条目怎么空了」）
            self.points_box.grid_remove()
        else:
            self.points_box.grid()
            self._refresh_points()

    # ------------------------------------------------------------------ 字段

    def on_page_select(self, _event: Any = None) -> None:
        """左栏换页：把右边整块换成这一页的字段与条目。"""
        if self._syncing:
            return
        selection = self.page_list.curselection()
        if not selection:
            return
        index = int(selection[0])
        page = text_model.pages()[index]
        if page == self.page:
            return
        self.page = page
        self.point_index = 0
        self._reset_undo_once()
        self._refresh_form()
        self.set_status("正在改：%s" % text_model.page_label(self.doc.text, page))

    def _entry(self, row: int, label: str, value: str, setter: Callable[[str], None],
               *, refresh_row: bool = False) -> int:
        ttk.Label(self.form, text=label, style="Head.TLabel").grid(
            row=row, column=0, sticky="w", pady=3, padx=(0, 10))
        variable = tk.StringVar(value=str(value))
        self._vars.append(variable)
        entry = ttk.Entry(self.form, textvariable=variable, width=1, font=self.body_font)
        entry.grid(row=row, column=1, sticky="ew", pady=3)
        entry.bind("<FocusIn>", lambda event: self._reset_undo_once())

        def on_write(*_args: Any) -> None:
            if self._syncing:
                return
            self._push_undo_once()
            setter(variable.get())
            self._mark_dirty()

        def on_leave(_event: Any = None) -> None:
            # 标题改了，左栏那一行要跟着变（打字时不动它，免得跟输入法抢焦点）
            if refresh_row:
                self._refresh_page_row(self.page)

        variable.trace_add("write", on_write)
        entry.bind("<FocusOut>", on_leave)
        return row + 1

    # ------------------------------------------------------------------ 条目

    def _points(self) -> List[str]:
        return text_model.points_of(self.doc.text, self.page)

    def _refresh_points(self) -> None:
        points = self._points()
        self._syncing = True
        self.point_list.delete(0, "end")
        for index, item in enumerate(points):
            self.point_list.insert("end", self._point_row(index, item))
        self._syncing = False
        self._show_point(min(self.point_index, max(len(points) - 1, 0)))

    def _point_row(self, index: int, value: str) -> str:
        text = " ".join(str(value).split())
        if len(text) > POINT_ROW_CHARS:
            text = text[:POINT_ROW_CHARS] + "…"
        return f"{index + 1}. {text}"

    def _refresh_point_row(self, index: int) -> None:
        points = self._points()
        if not (0 <= index < len(points)):
            return
        self._syncing = True
        self.point_list.delete(index)
        self.point_list.insert(index, self._point_row(index, points[index]))
        self.point_list.selection_clear(0, "end")
        self.point_list.selection_set(index)
        self._syncing = False

    def _show_point(self, index: int) -> None:
        """把第 index 条放进右边的编辑框。"""
        points = self._points()
        if not points:
            self._syncing = True
            self.point_text.delete("1.0", "end")
            self.point_text.edit_modified(False)
            self._syncing = False
            self.point_hint.configure(text="这一页没有正文")
            return
        self.point_index = max(0, min(int(index), len(points) - 1))
        self._syncing = True
        self.point_list.selection_clear(0, "end")
        self.point_list.selection_set(self.point_index)
        self.point_list.see(self.point_index)
        self.point_text.delete("1.0", "end")
        self.point_text.insert("1.0", points[self.point_index])
        self.point_text.edit_modified(False)
        self._syncing = False
        self._reset_undo_once()
        self.point_hint.configure(text=f"正在改第 {self.point_index + 1} / {len(points)} 条")

    def on_point_select(self, _event: Any = None) -> None:
        if self._syncing:
            return
        selection = self.point_list.curselection()
        if not selection:
            return
        index = int(selection[0])
        if index == self.point_index:
            return
        self._show_point(index)

    def on_point_modified(self, _event: Any = None) -> None:
        if self._syncing or not self.point_text.edit_modified():
            return
        self.point_text.edit_modified(False)
        points = self._points()
        if not (0 <= self.point_index < len(points)):
            return
        self._push_undo_once()
        points[self.point_index] = self.point_text.get("1.0", "end-1c")
        self._mark_dirty()
        self._refresh_point_row(self.point_index)

    def add_point(self) -> None:
        points = self._points()
        self.doc.push_undo()
        index = text_model.add_point(points, self.point_index + 1, PLACEHOLDER_POINT)
        self._mark_dirty()
        self._refresh_points()
        self._show_point(index)
        self.point_text.focus_set()
        self.set_status(f"在第 {index + 1} 条的位置插了一条（把占位那句改掉）")

    def remove_point(self) -> None:
        points = self._points()
        if len(points) <= 1:
            self.set_status("每一页至少要留一条正文：先把新的那条写好，再删这条", error=True)
            return
        self.doc.push_undo()
        text_model.remove_point(points, self.point_index)
        self._mark_dirty()
        self._refresh_points()
        self.set_status(f"删掉了第 {self.point_index + 1} 条")

    def move_point(self, delta: int) -> None:
        points = self._points()
        target = text_model.move_point(points, self.point_index, delta)
        if target == self.point_index:
            self.set_status("已经到头了，挪不动", error=True)
            return
        self.doc.push_undo()
        self._mark_dirty()
        self._refresh_points()
        self._show_point(target)
        self.set_status(f"这一条挪到了第 {target + 1} 位")

    # ------------------------------------------------------------------ 撤销与脏标记

    def _reset_undo_once(self) -> None:
        self._undo_pushed = False

    def _push_undo_once(self) -> None:
        """一次焦点里第一次真的改动：先把「改之前」的那一份压进撤销栈。"""
        if self._undo_pushed:
            return
        self.doc.push_undo()
        self._undo_pushed = True

    def _mark_dirty(self) -> None:
        self.dirty = True
        self.on_change()

    # ------------------------------------------------------------------ 命令

    def save(self) -> None:
        try:
            notes = self.doc.save()
        except ValueError as exc:
            self.set_status(str(exc), error=True)
            messagebox.showerror("还存不了", str(exc))
            return
        self.dirty = False
        self.on_change()
        self.refresh()
        self.set_status("；".join(notes) + "　→　回 Godot 里打开指南就能看到")

    def undo(self) -> None:
        if self.doc.undo():
            self.dirty = True
            self.on_change()
            self.refresh()
            self.set_status("撤销了一步")
        else:
            self.set_status("没有可撤销的了")

    def redo(self) -> None:
        if self.doc.redo():
            self.dirty = True
            self.on_change()
            self.refresh()
            self.set_status("重做了一步")
        else:
            self.set_status("没有可重做的了")

    def reload(self) -> None:
        if self.dirty and not messagebox.askyesno("重新载入", "有未保存的改动，确定丢掉并重新载入？"):
            return
        self.doc.reload()
        self.dirty = False
        self.on_change()
        self.refresh()
        self.set_status("已从 tools/guide_text.py 重新载入")

    def validate_now(self) -> None:
        problems = self.doc.problems()
        if problems:
            tail = f"（共 {len(problems)} 处）" if len(problems) > 3 else ""
            self.set_status("；".join(problems[:3]) + tail, error=True)
            return
        notes = self.doc.warnings()
        if notes:
            self.set_status("校验通过；" + "；".join(notes[:2]))
        else:
            self.set_status(f"校验通过：{self.doc.summary()}")

    def focus_first(self) -> None:
        """切到这个页签时把焦点放到该放的地方（不然 Del / Ctrl+Z 会打到别处）。"""
        self.point_text.focus_set()
