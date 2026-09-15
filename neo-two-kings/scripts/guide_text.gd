class_name GuideText
extends RefCounted

## 指南「纯文本」的加载层：把 data/guide_text.json 读成 PieceGuide 门面要的那些字段。
##
## 文案的**唯一数据源**是 tools/guide_text.py（手写，或用 tools/editor 的「文字」页签改），
## 由 tools/export_guide_text.py 导出成 JSON。这一层只搬运 + 报错：**不留任何兜底文案**，
## 读不出来就把问题交给上层说清楚（见 PieceGuide.load_problem），免得悄悄显示一份过期的话。
##
## JSON 的结构（tools/guide_text_kit.py 里定义，别手改）：
##
##   {
##     "format": "neo-two-kings/guide-text", "version": 1,
##     "intro_title": "怎么玩",
##     "intro_points": ["…", "…"],
##     "intro_card_glyph": "棋", "intro_card_short": "规则总览",
##     "pieces_title": "五种棋子",
##     "pieces": [{"symbol": "王", "short": "…", "tagline": "…", "points": ["…"]}],
##     "outro_title": "几个容易搞错的点",
##     "outro_points": ["…"]
##   }
##
## `load_text()` 把**兵种字**翻译成 PieceInfo.Kind（棋子的显示字只有 PieceInfo.SYMBOLS 一个来源），
## 所以上层拿到的 PIECE_NOTES 与以前写死在 GDScript 里的那份形状完全一样：
## `{kind, tagline, short, points}`。

## 文本 JSON 的位置、格式标记与游戏认识的结构版本。
const TEXT_PATH := "res://data/guide_text.json"
const TEXT_FORMAT := "neo-two-kings/guide-text"
const TEXT_VERSION := 1


## 读 + 校验指南文本。返回 `{intro_title, intro_points, intro_card_glyph, intro_card_short,
## pieces_title, pieces, outro_title, outro_points}`；读不动时返回空字典。
##
## 所有「哪里不对」都写进 `problems`（调用方拿它决定要不要在页面上把话说明白）——
## 这里刻意**不**自己 push_error：一次加载只该在日志里喊一嗓子，喊话的地方是 PieceGuide。
static func load_text(path: String = TEXT_PATH, problems: Array = []) -> Dictionary:
	var raw: Variant = _read_json(path, problems)
	if not (raw is Dictionary):
		return {}
	var table: Dictionary = raw
	if str(table.get("format", "")) != TEXT_FORMAT:
		problems.append("format 应该是「%s」（这个文件是别的东西生成的？）" % TEXT_FORMAT)
		return {}
	var version := int(table.get("version", 0))
	if version > TEXT_VERSION:
		problems.append("format 版本是 %d，比游戏认识的 %d 新——该更新游戏端的 GuideText 了" % [
			version, TEXT_VERSION,
		])
		return {}

	var out := {}
	out["intro_title"] = _text_of(table, "intro_title", problems)
	out["intro_points"] = _lines_of(table, "intro_points", problems)
	out["intro_card_glyph"] = _card_glyph(table, problems)
	out["intro_card_short"] = _text_of(table, "intro_card_short", problems)
	out["pieces_title"] = _text_of(table, "pieces_title", problems)
	out["pieces"] = _pieces_of(table, problems)
	out["outro_title"] = _text_of(table, "outro_title", problems)
	out["outro_points"] = _lines_of(table, "outro_points", problems)
	return out


# --- 解码 ---

## 一种棋子的说明。兵种字认不出来、或同一个兵种写了两遍时跳过这一条（问题记在 problems 里）。
static func _pieces_of(table: Dictionary, problems: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = table.get("pieces")
	if not (raw is Array):
		problems.append("pieces 要写成数组（每一种棋子一项）")
		raw = []
	var seen: Array[String] = []
	for index in range((raw as Array).size()):
		var where := "pieces[%d]" % index
		var item: Variant = (raw as Array)[index]
		if not (item is Dictionary):
			problems.append("%s 不是一条说明（应该是一个对象）" % where)
			continue
		var source: Dictionary = item
		var symbol := str(source.get("symbol", ""))
		var kind: Variant = PieceInfo.SYMBOL_KINDS.get(symbol)
		if kind == null:
			problems.append("%s 的棋子字「%s」不认识（只能是 %s）" % [where, symbol, _symbols_text()])
			continue
		if symbol in seen:
			problems.append("棋子「%s」写了两遍" % symbol)
			continue
		seen.append(symbol)
		out.append({
			"kind": kind,
			"tagline": _text_of(source, "tagline", problems, where),
			"short": _text_of(source, "short", problems, where),
			"points": _lines_of(source, "points", problems, where),
		})

	var missing := PackedStringArray()
	for kind in PieceInfo.SYMBOLS.keys():
		var symbol := str(PieceInfo.SYMBOLS[kind])
		if not (symbol in seen):
			missing.append(symbol)
	if not missing.is_empty():
		problems.append("这些棋子的说明不见了：%s（左栏的速查卡就是按它生成的）" % "、".join(missing))
	return out


## 一句话。缺字段、类型不对、空字符串都算问题（导出器本来就会拦，走到这里说明 JSON 被人手改了）。
static func _text_of(table: Dictionary, key: String, problems: Array, where: String = "") -> String:
	var label := key if where.is_empty() else "%s 的 %s" % [where, key]
	var raw: Variant = table.get(key)
	if raw == null:
		problems.append("%s 没有了" % label)
		return ""
	if not (raw is String) and not _is_number(raw):
		problems.append("%s 要写成一句话（收到 %s）" % [label, str(raw)])
		return ""
	var text := str(raw)
	if text.strip_edges().is_empty():
		problems.append("%s 是空的" % label)
	return text


## 左栏那张卡上的大字：必须正好一个字，不然卡片上会排出个怪东西。
static func _card_glyph(table: Dictionary, problems: Array) -> String:
	var glyph := _text_of(table, "intro_card_glyph", problems)
	if not glyph.is_empty() and glyph.length() != 1:
		problems.append("intro_card_glyph 要正好一个字（左栏那张卡上的大字），收到「%s」" % glyph)
	return glyph


## 一条条的正文。空行直接丢掉并记账：页面上的「・」是排版加的，空条目只会排出个孤零零的圆点。
static func _lines_of(table: Dictionary, key: String, problems: Array, where: String = "") -> Array[String]:
	var label := key if where.is_empty() else "%s 的 %s" % [where, key]
	var out: Array[String] = []
	var raw: Variant = table.get(key)
	if not (raw is Array):
		problems.append("%s 要写成字符串数组（一条一句）" % label)
		return out
	for item in (raw as Array):
		if not (item is String) and not _is_number(item):
			problems.append("%s 里有一条不是文字：%s" % [label, str(item)])
			continue
		var line := str(item)
		if line.strip_edges().is_empty():
			problems.append("%s 里有一条是空的" % label)
			continue
		out.append(line)
	if out.is_empty():
		problems.append("%s 一条正文都没有" % label)
	return out


# --- 读文件 ---

## 读 JSON。两条路都留着（与 GuideDemos._read_json 同一套做法）：
##   1. 直接读文件——开发时最直接，报错也只有我们自己的一条（json.parse 会给出错在哪一行）；
##   2. 退回资源加载——万一哪天它被当成资源打进包里（只有 load() 读得到）也还认。
static func _read_json(path: String, problems: Array) -> Variant:
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			problems.append("指南文本 %s 读出来是空的" % path)
			return null
		var json := JSON.new()
		if json.parse(text) != OK:
			problems.append("指南文本 %s 第 %d 行解析失败：%s" % [
				path, json.get_error_line(), json.get_error_message(),
			])
			return null
		return json.data
	if ResourceLoader.exists(path):
		var res: Variant = ResourceLoader.load(path)
		if res is JSON and (res as JSON).data != null:
			return (res as JSON).data
	problems.append("找不到指南文本 %s：请在仓库根目录跑一次 python tools/export_guide_text.py" % path)
	return null


# --- 小工具 ---

static func _symbols_text() -> String:
	var parts := PackedStringArray()
	for kind in PieceInfo.SYMBOLS.keys():
		parts.append(str(PieceInfo.SYMBOLS[kind]))
	return "/".join(parts)


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
