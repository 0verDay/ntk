#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""指南关键帧编辑器的入口。

    python tools/editor/editor.py

只用到标准库（tkinter），不需要装任何东西。
"""

from __future__ import annotations

import sys
from pathlib import Path

# tools/ 上路径：这样子模块里 `from editor import ...` 与 `import guide_demo_kit` 都能找到
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from editor import ui  # noqa: E402  （必须在 sys.path 处理之后）


def main() -> int:
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print("[失败] 这个 Python 没带 tkinter。Windows 官方版自带；", file=sys.stderr)
        print("       若用的是精简版/商店版，请换一个带 tkinter 的 Python，或找我改用网页版。", file=sys.stderr)
        return 1
    return ui.run()


if __name__ == "__main__":
    raise SystemExit(main())
