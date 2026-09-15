#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 `tools/guide_text.py` 里的指南纯文本导出成游戏读的那份 JSON。

    python tools/export_guide_text.py            # 校验 + 写出
    python tools/export_guide_text.py --check     # 只校验，并检查 JSON 是不是最新的
    python tools/export_guide_text.py --out 别的/路径.json

改完文案**一定要跑一次**，否则游戏（和测试）读到的还是旧的那份 JSON。
`--check` 会对比磁盘上的内容，适合放进提交前的自检：`tests/run-tests.ps1` 里已经挂了这一步。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 允许从任何目录运行（也允许 python -m tools.export_guide_text）
sys.path.insert(0, str(Path(__file__).resolve().parent))

import guide_text_kit as kit  # noqa: E402  （必须在 sys.path 处理之后）
from guide_text import guide_text as build  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "neo-two-kings" / "data" / "guide_text.json"


def _display_width(text: str) -> int:
    """中文按两格算，好让表格对齐。"""
    return sum(2 if ord(char) > 0x2E80 else 1 for char in text)


def _pad(text: str, width: int) -> str:
    return text + " " * max(0, width - _display_width(text))


def _setup_console() -> None:
    """控制台输出别乱码（与 export_guide_demos.py 同一套处理）。"""
    try:
        if not sys.stdout.isatty():
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        else:
            sys.stdout.reconfigure(errors="replace")
    except Exception:  # pragma: no cover - 环境相关
        pass


def main(argv=None) -> int:
    _setup_console()

    parser = argparse.ArgumentParser(
        description="把 tools/guide_text.py 导出成游戏读的指南文本 JSON",
    )
    parser.add_argument("--out", default=str(DEFAULT_OUT), help=f"输出路径（默认 {DEFAULT_OUT}）")
    parser.add_argument("--check", action="store_true", help="只校验、并检查磁盘上的 JSON 是否最新（不写文件）")
    args = parser.parse_args(argv)

    out_path = Path(args.out).resolve()

    # --- 1. 读文案（字段类型写错、棋子字不认识之类会在这里抛出来）---
    try:
        text = build()
    except kit.TextError as exc:
        print(f"[失败] 文案写错了：{exc}")
        return 1
    except TypeError as exc:
        # 构造器用的是显式关键字参数：名字写错时 Python 自己会拦下来
        #（并提示正确的名字）。这里翻成同一句人话，顺手带上出错的文件与行号。
        frame = sys.exc_info()[2]
        while frame is not None and frame.tb_next is not None:
            frame = frame.tb_next
        where = f"（{frame.tb_frame.f_code.co_filename}:{frame.tb_lineno}）" if frame is not None else ""
        print(f"[失败] 文案写错了{where}：{exc}")
        print("       多半是参数名拼错了——注意上面 Python 提示的那个「Did you mean …？」。")
        return 1

    # --- 2. 校验 ---
    problems = kit.validate(text)
    if problems:
        print(f"[失败] 文案有 {len(problems)} 处问题：")
        for problem in problems:
            print(f"  · {problem}")
        return 1

    # --- 3. 打个表，让人一眼看出这次改了多少 ---
    rows = kit.summary(text)
    print("文案来源：tools/guide_text.py")
    print(f"  {'页面':<14}{'条目':>6}{'字数':>8}")
    for page, points, chars in rows:
        print(f"  {_pad(page, 14)}{points:>6}{chars:>8}")
    total_points = sum(row[1] for row in rows)
    total_chars = sum(row[2] for row in rows)
    print(f"  {'合计':<14}{total_points:>6}{total_chars:>8}")
    print(f"[通过] 文案校验通过：{len(rows)} 页 / {total_points} 条 / {total_chars} 字")

    # 警告不拦保存，只提醒（比如「short 太长，左栏卡片会换行」）
    for note in kit.warnings(text):
        print(f"[注意] {note}")

    # --- 4. 写出 / 对比 ---
    body = kit.dumps(text)
    old = out_path.read_text(encoding="utf-8") if out_path.exists() else None

    if args.check:
        if old == body:
            print(f"[通过] {out_path} 与 tools/guide_text.py 完全一致（最新）")
            return 0
        if old is None:
            print(f"[失败] {out_path} 还不存在：请跑一次 python tools/export_guide_text.py")
        else:
            print(f"[失败] {out_path} 与 tools/guide_text.py 不一致（改了文案忘了导出？）")
            print("       跑一次 python tools/export_guide_text.py 就会同步。")
        return 1

    changed = kit.write(out_path, text)
    if changed:
        print(f"[通过] 已写出 {out_path}（内容有变化）")
    else:
        print(f"[通过] {out_path} 已是最新（内容没变，没动文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
