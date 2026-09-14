#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 `tools/demos/*.py` 里的演示剧本导出成游戏读的那份 JSON。

    python tools/export_guide_demos.py            # 校验 + 写出
    python tools/export_guide_demos.py --check     # 只校验，并检查 JSON 是不是最新的
    python tools/export_guide_demos.py --out 别的/路径.json

改完演示**一定要跑一次**，否则游戏（和测试）读到的还是旧的那份 JSON。
`--check` 会对比磁盘上的内容，适合放进提交前的自检：`tests/run-tests.ps1` 里已经挂了这一步。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 允许从任何目录运行（也允许 python -m tools.export_guide_demos）
sys.path.insert(0, str(Path(__file__).resolve().parent))

import guide_demo_kit as kit  # noqa: E402  （必须在 sys.path 处理之后）
from demos import collect  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "neo-two-kings" / "data" / "guide_demos.json"


def _display_width(text: str) -> int:
    """中文按两格算，好让表格对齐。"""
    return sum(2 if ord(ch) > 0x2E80 else 1 for ch in text)


def _pad(text: str, width: int) -> str:
    return text + " " * max(0, width - _display_width(text))


def _setup_console() -> None:
    """控制台输出别乱码。

    接着终端跑时交给 Python 的默认行为（它按控制台代码页走，5.1 的 cp936 与 pwsh 的 UTF-8 都对）；
    被重定向到管道/文件时（CI、harness、`> log.txt`）统一成 UTF-8，读的人不用猜编码。
    """
    try:
        if not sys.stdout.isatty():
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        else:
            sys.stdout.reconfigure(errors="replace")  # 编码装不下的字符别把脚本炸掉
    except Exception:  # pragma: no cover - 环境相关
        pass


def main(argv=None) -> int:
    _setup_console()

    parser = argparse.ArgumentParser(
        description="把 tools/demos/*.py 导出成游戏读的指南演示 JSON",
    )
    parser.add_argument("--out", default=str(DEFAULT_OUT), help=f"输出路径（默认 {DEFAULT_OUT}）")
    parser.add_argument("--check", action="store_true", help="只校验、并检查磁盘上的 JSON 是否最新（不写文件）")
    args = parser.parse_args(argv)

    out_path = Path(args.out).resolve()

    # --- 1. 收集剧本（拼错字段、坐标越界之类会在这里抛出来）---
    try:
        demos = collect()
    except kit.DemoError as exc:
        print(f"[失败] 剧本写错了：{exc}")
        return 1
    except TypeError as exc:
        # 关键帧函数用的是显式关键字参数：名字写错时 Python 自己就会拦下来
        #（而且会提示正确的名字，比如 "Did you mean 'moves_text'?"）。
        # 这里把它翻成同一句人话，别让作者对着一堆 traceback 发愣；顺手带上出错的文件与行号。
        frame = sys.exc_info()[2]
        while frame is not None and frame.tb_next is not None:
            frame = frame.tb_next
        where = f"（{frame.tb_frame.f_code.co_filename}:{frame.tb_lineno}）" if frame is not None else ""
        print(f"[失败] 剧本写错了{where}：{exc}")
        print("       多半是参数名拼错了——注意上面 Python 提示的那个「Did you mean …？」。")
        return 1

    # --- 2. 校验 ---
    problems = kit.validate(demos)
    if problems:
        print(f"[失败] 剧本有 {len(problems)} 处问题：")
        for problem in problems:
            print(f"  · {problem}")
        return 1

    # --- 3. 打个表，让人一眼看出这次改了多少 ---
    rows = kit.summary(demos)
    print("剧本来源：tools/demos/*.py")
    print(f"  {'兵种':<6}{'段数':>6}{'帧数':>7}{'时长':>9}")
    for symbol, demo_count, frame_count, seconds in rows:
        print(f"  {_pad(symbol, 6)}{demo_count:>6}{frame_count:>7}{seconds:>8.1f}s")
    total_demos = sum(r[1] for r in rows)
    total_frames = sum(r[2] for r in rows)
    total_seconds = sum(r[3] for r in rows)
    print(f"  {'合计':<6}{total_demos:>6}{total_frames:>7}{total_seconds:>8.1f}s")
    print(f"[通过] 剧本校验通过：{total_demos} 段动画 / {total_frames} 帧")

    # 警告不拦保存，只提醒（比如「相邻两帧画面一模一样，多半是复制出来忘了改」）
    for note in kit.warnings(demos):
        print(f"[注意] {note}")

    # --- 4. 写出 / 对比 ---
    text = kit.dumps(demos)
    old = out_path.read_text(encoding="utf-8") if out_path.exists() else None

    if args.check:
        if old == text:
            print(f"[通过] {out_path} 与 tools/demos/*.py 完全一致（最新）")
            return 0
        if old is None:
            print(f"[失败] {out_path} 还不存在：请跑一次 python tools/export_guide_demos.py")
        else:
            print(f"[失败] {out_path} 与 tools/demos/*.py 不一致（改了剧本忘了导出？）")
            print("       跑一次 python tools/export_guide_demos.py 就会同步。")
        return 1

    changed = kit.write(out_path, demos)
    if changed:
        print(f"[通过] 已写出 {out_path}（内容有变化）")
    else:
        print(f"[通过] {out_path} 已是最新（内容没变，没动文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
