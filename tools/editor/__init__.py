# -*- coding: utf-8 -*-
"""指南动画的可视化编辑器。

入口：

    python tools/editor/editor.py

一帧就是一张画：棋子摆在哪、画哪几条箭头、高亮哪些格子、下面写哪句话、停多久。
工具只有三个（摆子 / 箭头 / 高亮），游戏端只按顺序画、不跑棋规。

它读写 `tools/demos/*.py`（文件开头的说明原样保留，只重写「剧本区」那一段），
保存时顺手刷新 `neo-two-kings/data/guide_demos.json`，所以保存完直接回游戏里看就行。

模块分工：

* `model.py`   数据层：载入 / 改 / 撤销 / 校验 / 保存（不碰界面，可单独测）
* `codegen.py` Demo/Frame 对象 → Python 源码（只重写「剧本区」）
* `ui.py`      Tkinter 界面（摆子 / 箭头 / 高亮 三个工具）
* `selftest.py` 无窗口自检：载入 → 渲染 → 与原文件逐字节一致
"""
