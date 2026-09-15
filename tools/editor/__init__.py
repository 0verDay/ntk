# -*- coding: utf-8 -*-
"""指南的可视化编辑器（一个窗口两个页签）。

入口：

    python tools/editor/editor.py

* **动画**页签：一帧就是一张画——棋子摆在哪、画哪几条箭头、高亮哪些格子、下面写哪句话、
  停多久、镜头看哪几格。工具四个（摆子 / 箭头 / 高亮 / 镜头），游戏端只按顺序画、不跑棋规。
  它读写 `tools/demos/*.py`，保存时顺手刷新 `neo-two-kings/data/guide_demos.json`。
* **文字**页签：指南上所有的字——怎么玩、左栏小标题、每种棋子的摘要与一条条正文、
  容易搞错的那一页。左边选页、右边改字段与条目。
  它读写 `tools/guide_text.py`，保存时顺手刷新 `neo-two-kings/data/guide_text.json`。

两个页签都是「只重写文件里的『剧本区』那一段」，文件开头的说明原样保留，
所以保存完直接回游戏里看就行。

模块分工：

* `model.py`       动画页签的数据层：载入 / 改 / 撤销 / 校验 / 保存（不碰界面，可单独测）
* `codegen.py`     Demo/Frame 对象 → Python 源码（只重写「剧本区」）
* `text_model.py`  文字页签的数据层：页面 / 条目操作 / 撤销 / 校验 / 保存
* `text_codegen.py` GuideText 对象 → `tools/guide_text.py` 的源码
* `text_ui.py`     「文字」页签的界面（左边选页、右边改字段与条目）
* `atomic.py`      原子写文件（两个页签保存时共用）
* `ui.py`          Tkinter 窗口：两个页签 + 共用的状态栏，快捷键按页签分流
* `selftest.py`    无窗口自检：两个页签都是「载入 → 渲染 → 与原文件逐字节一致」
"""
