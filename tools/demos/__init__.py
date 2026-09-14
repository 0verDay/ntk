# -*- coding: utf-8 -*-
"""五个兵种的演示剧本清单——**想改演示就先看这里，再进各自的模块**。

一个兵种一个模块（`king.py` / `archer.py` / `knight.py` / `shield.py` / `pawn.py`），
每个模块导出两样东西：

* `SYMBOL`  兵种显示字（王/弓/骑/盾/步），决定这段演示挂在指南的哪张卡片上；
* `demos()` 这个兵种的演示列表（骑有两段：连跳 + 夹击）。

加一个新兵种、或者给某个兵种加/删一段演示，都只需要动对应模块的 `demos()`。
顺序由 `guide_demo_kit.PIECE_SYMBOLS` 决定（王 → 弓 → 骑 → 盾 → 步）。
"""

from guide_demo_kit import PIECE_SYMBOLS, DemoError

from . import archer, king, knight, pawn, shield

#: 按指南页面里的顺序（= PIECE_SYMBOLS 的顺序）。
MODULES = (king, archer, knight, shield, pawn)


def collect():
    """收集全部演示，返回 `{兵种字: [Demo, ...]}`；写错了当场抛 DemoError。"""
    out = {}
    for module in MODULES:
        symbol = module.SYMBOL
        source = "tools/" + module.__name__.replace(".", "/") + ".py"
        if symbol in out:
            raise DemoError(f"「{symbol}」被两个模块同时声明了（{source}）")
        if symbol not in PIECE_SYMBOLS:
            raise DemoError(f"{source} 里的 SYMBOL = {symbol!r} 不是兵种字（只能是 {'/'.join(PIECE_SYMBOLS)}）")
        demos = list(module.demos())
        for demo in demos:
            demo.source = source
        out[symbol] = demos

    missing = [s for s in PIECE_SYMBOLS if s not in out]
    if missing:
        raise DemoError(f"还没有写演示的兵种：{'、'.join(missing)}（每个兵种都要有，缺了就补一个模块）")
    return out
