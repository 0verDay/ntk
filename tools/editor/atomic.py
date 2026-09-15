# -*- coding: utf-8 -*-
"""原子写文件：先写同目录下的临时文件、再替换目标。

写一半崩掉（断电、异常、Ctrl+C）也不会留下半个 `tools/demos/king.py` 或半个
`tools/guide_text.py`。动画编辑器与文字页签共用这一份实现。
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Union


def write_text(path: Union[str, Path], text: str) -> None:
    """把 `text` 原子地写到 `path`（UTF-8、LF 换行，和仓库里其它文件一致）。"""
    path = Path(path)
    handle_fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(handle_fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
