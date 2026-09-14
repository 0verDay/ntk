#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编辑器的无窗口自检：`python tools/editor/selftest.py`（退出码 0 = 全通过）。

它守住的是「编辑器不会悄悄改坏剧本」这件事：

1. 磁盘上的五个模块**已经是规范形式**——所以打开编辑器、什么都不改就保存，不会产生无谓改动；
2. **往返不丢信息**：载入 → 渲染成源码 → 再载入，数据必须逐字节相同
   （棋子、箭头、高亮、文字、停留时间，任何一处抄错都会在这里红）；
3. 渲染是**幂等**的：同一份数据渲染两次结果一样；
4. 各种编辑操作（摆子 / 擦除 / 高亮 / 画箭头 / 删箭头 / 增删帧 / 撤销重做）改的都是该改的地方，
   而且**全程不写磁盘**；
5. 「重新载入」是真的重新从磁盘导入（不是把内存里的旧对象再拿一遍）。

它同时是 `codegen` 的回归网：改渲染器时先跑它。
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
sys.path.insert(0, str(TOOLS))

import guide_demo_kit as kit  # noqa: E402
from editor import codegen, model  # noqa: E402

_passed = 0
_failed = 0


def check(condition: bool, title: str) -> bool:
    global _passed, _failed
    if condition:
        _passed += 1
        print(f"  [通过] {title}")
    else:
        _failed += 1
        print(f"  [失败] {title}")
    return bool(condition)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # pragma: no cover
        pass

    print("=== 编辑器自检 ===")
    doc = model.Doc()

    print("-- 剧本本身 --")
    problems = doc.problems()
    check(not problems, "五个兵种的动画都过校验" + ("" if not problems else f"（{problems[0]}）"))
    check(doc.summary().startswith("6 段动画"), f"摘要看起来对：{doc.summary()}")
    check(len(doc.symbols()) == 5, f"五个兵种都在：{'、'.join(doc.symbols())}")

    print("-- 渲染器：磁盘上的模块已经是规范形式 --")
    headers: Dict[str, str] = {}
    for symbol, demos in doc.demos.items():
        path = doc.module_path(symbol)
        text = path.read_text(encoding="utf-8")
        headers[symbol] = codegen.split_header(text)
        check(codegen.render_module(headers[symbol], demos) == text,
              f"{path.name} 渲染后与原文件一字不差（保存不会产生无谓改动）")
        check(codegen.MARKER_BEGIN in text, f"{path.name} 有「剧本区」标记")

    print("-- 渲染 → 再载入：数据不能有任何变化 --")
    # 不落磁盘：直接把渲染出来的源码 exec 一遍再取 demos()，测的是同一段源码
    for symbol, demos in doc.demos.items():
        source = codegen.render_module(headers[symbol], demos)
        namespace: Dict[str, Any] = {"__name__": f"probe_{symbol}"}
        exec(compile(source, f"<{symbol}.py>", "exec"), namespace)
        again: List[Any] = list(namespace["demos"]())
        check(kit.dumps({symbol: again}) == kit.dumps({symbol: demos}),
              f"「{symbol}」渲染后再载入，数据一字不差")
        check(codegen.render_module(codegen.split_header(source), again) == source,
              f"「{symbol}」再渲染一次结果相同（幂等）")

    print("-- 帧上的编辑操作（全在内存里，不写磁盘） --")
    demo = doc.demos["步"][0]
    frame = model.new_frame_like()  # 一张空棋盘，断言简单些
    model.set_piece(frame, (6, 6), "骑", "green")
    check(model.piece_at(frame, (6, 6)) == ["骑", "green"], "能在一帧上摆一枚棋子（阵营是写明的）")
    model.erase_piece(frame, (6, 6))
    check(model.piece_at(frame, (6, 6)) is None, "能擦掉那一帧的一枚棋子")
    model.set_piece(frame, (0, 0), "王", "red")
    model.set_piece(frame, (1, 1), "步", "green")
    check(len(frame.pieces) == 2, "一帧可以同时有好几枚棋子")

    check(not model.has_highlight(frame, (2, 2)), "高亮默认是关的")
    check(model.toggle_highlight(frame, (2, 2)) is True, "点一下打开高亮")
    check(model.has_highlight(frame, (2, 2)), "确实亮着")
    check(model.toggle_highlight(frame, (2, 2)) is False, "再点一下关掉高亮")
    check(not model.has_highlight(frame, (2, 2)), "确实关了")

    model.add_arrow(frame, (0, 0), (1, 1), "shot")
    check(len(frame.arrows) == 1 and frame.arrows[0]["style"] == "shot", "能画一条箭头（样式也记下了）")
    model.add_arrow(frame, (1, 1), (3, 3))
    check(len(frame.arrows) == 2, "能画第二条")
    check(model.remove_arrows_touching(frame, (1, 1)) == 2, "碰着 (1,1) 的两条箭头一起删掉")
    check(not frame.arrows, "删干净了")
    model.add_arrow(frame, (0, 0), (1, 1))
    model.remove_arrow_at(frame, 0)
    check(not frame.arrows, "也能按序号删某一条箭头")

    fresh = model.new_frame_like(frame)
    check(fresh.pieces == frame.pieces and list(fresh.highlights) == list(frame.highlights),
          "新建的帧沿用上一帧的棋子与高亮")
    check(not fresh.arrows, "但箭头不沿用（新一帧要重新画）")
    check(str(fresh.text).strip() != "", "新帧自带一句占位说明（不然一建出来就是红的）")
    check(str(model.new_demo().caption).strip() != "" and model.new_demo().frames, "新建的动画有标题和一帧")

    print("-- 镜头（这一帧显示哪几格）--")
    lens = model.new_frame_like()
    check(model.view_of(lens) is None, "默认不写镜头（＝按内容自动推）")
    model.set_piece(lens, (1, 1), "王", "red")
    model.set_piece(lens, (3, 4), "步", "green")
    model.add_arrow(lens, (1, 1), (3, 4))
    check(model.content_bounds(lens) == (1, 1, 3, 4),
          f"按内容贴合算出来的是内容包围盒 {model.content_bounds(lens)}")
    try:
        model.set_view(lens, 5, 5, 4, 4, 7)
        check(False, "镜头伸出棋盘时应该拒绝")
    except ValueError as exc:
        check("伸出棋盘" in str(exc), f"镜头伸出棋盘会被拒绝（{exc}）")
    try:
        model.set_view(lens, 0, 0, 0, 3, 7)
        check(False, "镜头宽高为 0 时应该拒绝")
    except ValueError as exc:
        check("正数" in str(exc), f"镜头宽高必须是正数（{exc}）")
    model.set_view(lens, 1, 1, 3, 4, 7)
    check(model.view_of(lens) == (1, 1, 3, 4), "能设上镜头")
    check(not model.content_outside_view(lens), "内容都在镜头里时不报「看不见」")
    model.set_view(lens, 1, 1, 2, 2, 7)
    check(bool(model.content_outside_view(lens)), "有东西落在镜头外时列得出来（只提醒、不拦）")
    inherited = model.new_frame_like(lens)
    check(model.view_of(inherited) == (1, 1, 2, 2), "新建的帧沿用上一帧的镜头（不用每帧重框）")
    model.clear_view(lens)
    check(model.view_of(lens) is None, "能恢复成「按内容自动推」")
    holder = kit.Demo(caption="镜头往返", size=7, frames=[
        kit.Frame(text="一", view=kit.rect(0, 0, 4, 4)),
        kit.Frame(text="二", view=kit.rect(2, 2, 3, 3), view_hold=True),
    ])
    source = codegen.render_module("from guide_demo_kit import Demo, Frame, rect\n\nSYMBOL = \"王\"\n",
                                  [holder])
    check("view=rect(0, 0, 4, 4)," in source and "view_hold=True," in source,
          "镜头与「硬切」都会渲染进源码")
    namespace: Dict[str, Any] = {"__name__": "probe_view"}
    exec(compile(source, "<view.py>", "exec"), namespace)
    again = list(namespace["demos"]())[0]
    check(kit.dumps({"王": [again]}) == kit.dumps({"王": [holder]}),
          "镜头渲染后再载入，数据一字不差")
    check(codegen.render_module(codegen.split_header(source), [again]) == source,
          "带镜头的模块再渲染一次结果相同（幂等）")

    print("-- 棋盘边长 --")
    model.set_size(demo, 8)
    check(demo.size == 8, "能改大棋盘")
    try:
        model.set_size(demo, 2)
        check(False, "缩到装不下棋子时应该拒绝")
    except ValueError as exc:
        check("挤出棋盘" in str(exc) and "(" in str(exc),
              f"缩到装不下棋子时会拒绝并说清是哪一枚（{exc}）")
    model.set_size(demo, 7)

    print("-- 撤销 / 重做 --")
    doc.push_undo()
    before = kit.dumps(doc.demos)
    doc.demos["步"][0].caption = "改一下"
    check(kit.dumps(doc.demos) != before, "改动确实生效了")
    doc.undo()
    check(kit.dumps(doc.demos) == before, "撤销能回到改动之前")
    doc.redo()
    check(kit.dumps(doc.demos) != before, "重做能再走回去")

    print("-- 「重新载入」是真的从磁盘重新导入 --")
    before_id = id(doc.demos["王"][0])
    doc.reload()
    check(id(doc.demos["王"][0]) != before_id,
          "重新载入换的是新对象（模块缓存已清掉，手改 .py 后点它就能读到）")
    check(not doc.problems(), "重新载入之后仍然过校验")

    print("-- 不该写磁盘的地方确实没写 --")
    modules = sorted(path.name for path in model.DEMOS_DIR.glob("*.py"))
    check(len(modules) >= 5, f"tools/demos 下有 {len(modules)} 个模块：{'、'.join(modules)}")
    leftovers = list(model.DEMOS_DIR.glob("*.tmp"))
    check(not leftovers, f"没有留下临时文件（{leftovers}）")

    print(f"\n通过 {_passed} 项，失败 {_failed} 项")
    return 1 if _failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
