class_name PieceGuide
extends RefCounted

## 棋子指南的**门面**：界面代码（guide.gd 的页面、game.gd 的长按卡片）只问这里。
##
## 指南有两样东西，各走一条「Python 工具 → data/*.json → 这里读」的流水线：
##
##   纯文本（标题 / 摘要 / 一条条说明）
##       tools/guide_text.py                    你改文案的地方
##           ↓ python tools/export_guide_text.py
##       data/guide_text.json                   游戏读它（别手改）
##           ↓ GuideText.load_text()
##       本文件的 INTRO_* / PIECE_NOTES / OUTRO_*  ← 界面要的那些字段
##
##   演示（会动的棋盘）＝「纯动画」，每一帧画什么都在 Python 里写死
##       tools/demos/*.py                       你写剧本的地方（棋子 / 关键帧 / 文字）
##           ↓ python tools/export_guide_demos.py
##       data/guide_demos.json                  游戏读它（别手改）
##           ↓ GuideDemos.load_demos() → GuideDemos.build()
##       帧列表 → GuideDemo 画出来（不跑棋规：画面上就是你摆的样子）
##
## ⚠ **本文件里一个字都不写**：想改措辞请改 tools/guide_text.py（跑一次导出），
##    或者在 tools/editor 的「文字」页签里改。这里只做加载与检索。
## ⚠ 文案必须与 rules.gd 保持一致。改棋规时把 tools/guide_text.py 一起改。
## ⚠ tests/test_menu_ui.gd 会核对每种棋子都有说明，并核对「怎么玩」里写的兵力与真实初始布局一致。
## ⚠ tests/test_guide_demos.gd 会核对每种棋子都配有演示。
##
## 棋子的名字与显示字一律取自 PieceInfo.SYMBOLS，所以不可能和棋盘上的字对不上。

# --- 共用配色（指南页面与长按卡片保持一致；配色不是文案，留在代码里） ---
const HEADING_COLOR := Color(0.117647, 0.184314, 0.360784)
const BODY_COLOR := Color(0.223529, 0.254902, 0.317647)
const ACCENT_COLOR := Color(0.121569, 0.372549, 0.815686)

# --- 文案（_static_init 里从 data/guide_text.json 读进来，见文件开头的流水线） ---
## 「怎么玩」那一页。
static var INTRO_TITLE := ""
static var INTRO_POINTS: Array[String] = []
## 左栏「怎么玩」那张速查卡上的大字与一句话。
static var INTRO_CARD_GLYPH := ""
static var INTRO_CARD_SHORT := ""
## 左栏里棋子卡上方的小标题。
static var PIECES_TITLE := ""
## 每种棋子的说明：`{kind, tagline, short, points}`（顺序就是指南里的顺序）。
static var PIECE_NOTES: Array[Dictionary] = []
## 「几个容易搞错的点」那一页。
static var OUTRO_TITLE := ""
static var OUTRO_POINTS: Array[String] = []

## 加载时的问题（空 = 一切正常）。界面拿它在页面上把「文本没读出来」说清楚，
## 而不是显示一页空白——文案全在 JSON 里，读不到就没有可显示的东西。
static var _load_problem := ""


## 脚本第一次被用到时读一次 JSON（读一次就留在 static 变量里，之后只是取字段）。
static func _static_init() -> void:
	var problems: Array = []
	var loaded := GuideText.load_text(GuideText.TEXT_PATH, problems)
	INTRO_TITLE = str(loaded.get("intro_title", ""))
	INTRO_POINTS = _strings(loaded.get("intro_points"))
	INTRO_CARD_GLYPH = str(loaded.get("intro_card_glyph", ""))
	INTRO_CARD_SHORT = str(loaded.get("intro_card_short", ""))
	PIECES_TITLE = str(loaded.get("pieces_title", ""))
	PIECE_NOTES = _notes(loaded.get("pieces"))
	OUTRO_TITLE = str(loaded.get("outro_title", ""))
	OUTRO_POINTS = _strings(loaded.get("outro_points"))

	_load_problem = _join_problems(problems)
	if not _load_problem.is_empty():
		# 日志里喊一嗓子：指南页面上也会把同一段话显示出来（见 guide.gd）
		push_error("指南文本没读出来（页面上的文字都来自 data/guide_text.json）：\n%s" % _load_problem)


## 读不动时字段会缺席，这里一律**复制成带类型的数组**再赋值：
## 直接把 Dictionary.get() 的默认值 `[]` 赋给 Array[String] 会报「类型对不上」，
## 而那正好发生在最需要它别出错的时候（JSON 没导出来）。
static func _strings(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for item in (value as Array):
			out.append(str(item))
	return out


static func _notes(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if value is Array:
		for item in (value as Array):
			if item is Dictionary:
				out.append(item)
	return out


## 加载时的问题（空 = 没问题）。guide.gd 用它决定要不要在页面上放一条「没读出来」的提示。
static func load_problem() -> String:
	return _load_problem


static func _join_problems(problems: Array) -> String:
	var lines := PackedStringArray()
	for problem in problems:
		lines.append("・%s" % str(problem))
	return "\n".join(lines)


## 取某种棋子的说明条目；没有对应条目时返回空字典。
static func note_for(kind: int) -> Dictionary:
	for note in PIECE_NOTES:
		if note["kind"] == kind:
			return note
	return {}


## 某种棋子的演示（会动的棋盘）剧本列表。
##
## 剧本来自 data/guide_demos.json（tools/export_guide_demos.py 从 tools/demos/*.py 生成）——
## 读不到文件、或者某种棋子还没写演示，都返回空数组——指南页面照常显示纯文字，不会报错崩掉。
static func demos_for(kind: int) -> Array:
	var demos: Array = all_demos().get(symbol_of(kind), [])
	return demos


## 全部演示剧本 `{兵种字: Array[剧本]}`，按兵种字取。
## 第一次问的时候才去读文件，之后就吃缓存（读文件这一步在打开指南时只该发生一次）。
static func all_demos() -> Dictionary:
	if not _demos_loaded:
		_demos_loaded = true
		_demos_by_symbol = GuideDemos.load_demos()
	return _demos_by_symbol


## 剧本缓存与「读过没有」的标记。读失败时是空字典（演示全部缺席，其它照常）。
static var _demos_by_symbol: Dictionary = {}
static var _demos_loaded := false


## 某种棋子的显示字（棋盘上那个汉字）。
static func symbol_of(kind: int) -> String:
	return str(PieceInfo.SYMBOLS.get(kind, "?"))
