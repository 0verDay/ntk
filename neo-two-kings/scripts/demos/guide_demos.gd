class_name GuideDemos
extends RefCounted

## 指南里那些「动画」的加载层：把 data/guide_demos.json 读成 **帧列表**。
##
## 指南从这一版起是**纯动画**：每一帧自己写清了画哪几枚棋子、画哪几条箭头、高亮哪些格子、
## 下面写哪句话、停多久。所以这一层**不碰 rules.gd**——它只搬运数据，不判断任何棋规。
## （代价记在 tools/README.md 里：画面不再和棋规自动对账，演示讲得对不对全靠作者。）
##
## JSON 由 `tools/export_guide_demos.py` 从 `tools/demos/*.py` 生成，结构是：
##
##   demos.{兵种字} = [ {caption, size, frames: [frame, ...]} ]
##   frame = {
##       text,                                  # 棋盘下方那句话
##       hold,                                  # 这一帧停多久（秒）
##       pieces:     {"x,y": [兵种字, "red"|"green"]},
##       highlights: [[x, y], ...],
##       arrows:     [{from: [x, y], to: [x, y], style: "move"|"shot"|"hop"}],
##       view:       [x, y, w, h],              # 可选：这一帧的镜头（不写就按内容自动推）
##       view_hold:  true,                      # 可选：换到这一帧时视口硬切、不做过渡
##   }
##
## `build()` 把一份剧本变成绘制层要的帧列表（纯数据，不含节点）：
##
##   state      Dictionary[Vector2i -> PieceInfo]  这一帧画出来的棋子
##   highlight  Dictionary[Vector2i -> String]     高亮的格子
##   arrows     Array[Dictionary]                  {from: Vector2i, to: Vector2i, kind: String}
##   view       Rect2i                              这一帧的镜头（像素绘制时只画这里面）
##   view_hold  bool                                换帧时视口是否硬切
##   text       String                             棋盘下方那句话
##   hold       float                              这一帧停多久（秒）

## 剧本 JSON 的位置与格式标记。
const SCRIPTS_PATH := "res://data/guide_demos.json"
const SCRIPTS_FORMAT := "neo-two-kings/guide-frames"
## 箭头样式（颜色由绘制层决定，见 guide_demo.gd 的 _draw_arrows）。
const ARROW_STYLES := ["move", "shot", "hop"]
## 高亮格在帧里用的标签（绘制层只认这个）。
const HIGHLIGHT_LABEL := "zone"
## 一帧没有 hold（或 <= 0）时的兜底停留时间：宁可演得难看，也不能让动画卡住。
const FALLBACK_HOLD := 2.0


## 读取剧本 JSON，返回 `{兵种字: Array[剧本]}`（就是 PieceGuide.demos_for 要的东西）。
## 读不到 / 格式不对 / 某一段写坏了：报错并返回能用的部分（空就是全都没有）。
static func load_demos(path: String = SCRIPTS_PATH) -> Dictionary:
	var raw: Variant = _read_json(path)
	if raw == null:
		return {}
	if not (raw is Dictionary):
		push_error("演示剧本 %s 的顶层应该是一个对象" % path)
		return {}
	var table: Dictionary = raw
	if str(table.get("format", "")) != SCRIPTS_FORMAT:
		push_error("演示剧本 %s 的 format 应该是「%s」（这个文件是别的东西生成的？）" % [path, SCRIPTS_FORMAT])
		return {}
	var table_demos: Variant = table.get("demos", {})
	if not (table_demos is Dictionary):
		push_error("演示剧本 %s 里缺少 demos 段" % path)
		return {}

	var result := {}
	for symbol in (table_demos as Dictionary).keys():
		var list: Variant = (table_demos as Dictionary)[symbol]
		var decoded: Array = []
		if not (list is Array):
			push_error("演示剧本「%s」不是一个数组" % str(symbol))
			result[str(symbol)] = decoded
			continue
		for index in range((list as Array).size()):
			var problems: Array = []
			var demo := decode_demo((list as Array)[index], str(symbol), problems)
			if problems.is_empty() and not demo.is_empty():
				decoded.append(demo)
				continue
			var detail := ""
			for problem in problems:
				detail += "\n    · %s" % str(problem)
			push_error("演示剧本「%s」第 %d 段读不出来，已整段跳过：%s" % [str(symbol), index + 1, detail])
		result[str(symbol)] = decoded
	return result


## 剧本 → 帧列表。空剧本返回空数组。
static func build(demo: Dictionary) -> Array:
	var frames: Array = []
	if demo.is_empty() or not demo.has("frames"):
		return frames
	var size := int(demo.get("size", 7))
	var raw_frames: Array = demo.get("frames", [])
	for index in range(raw_frames.size()):
		var frame: Dictionary = raw_frames[index]
		var hold := float(frame.get("hold", 0.0))
		if hold <= 0.0:
			# 没有停留时间的帧会让播放层停在那儿——和以前「回合漏写 duration」是同一个坑。
			push_error("「%s」第 %d 帧没有写 hold（或 <= 0）：改用兜底 %.1f 秒" % [
				str(demo.get("caption", "")), index + 1, FALLBACK_HOLD,
			])
			hold = FALLBACK_HOLD
		frames.append({
			"state": frame.get("state", {}),
			"highlight": frame.get("highlight", {}),
			"arrows": frame.get("arrows", []),
			"view": frame.get("view", Rect2i()),
			"view_hold": bool(frame.get("view_hold", false)),
			"text": str(frame.get("text", "")),
			"hold": hold,
			# 棋盘边长也带进每一帧：绘制层要靠它算画布范围（见 bounds_of），
			# 不然只能猜一个 7，而小棋盘的演示会因此多算一圈。
			"board_size": size,
		})
	return frames


# --- 显示范围（镜头看哪几格）---

## 这一帧的镜头范围（格子坐标）。作者写了 `view` 就用它，没写则由内容自动推。
##
## 自动推的规则：这一帧的「棋子 + 高亮 + 箭头两端」的包围盒——没有外圈留白，
## 外圈是画布那一层的事（见 canvas_of）。这一帧空着（比如「撤走」之后什么都没了）时
## 返回空 Rect2i，调用方应当「保持上一帧的镜头不动」而不是跳回整块棋盘。
static func view_of(frame: Dictionary) -> Rect2i:
	var explicit: Variant = frame.get("view")
	if explicit is Rect2i and (explicit as Rect2i).size.x > 0 and (explicit as Rect2i).size.y > 0:
		return explicit
	return frame_bounds(frame)


## 这一帧是不是「作者写死了镜头」。注意空 Rect2i 不算——那只是「没写」的占位。
static func has_view(frame: Dictionary) -> bool:
	var explicit: Variant = frame.get("view")
	return explicit is Rect2i and (explicit as Rect2i).size.x > 0 and (explicit as Rect2i).size.y > 0


## 换到这一帧时，镜头要不要**硬切**（true）而不是滑过去（false）。
static func view_hold(frame: Dictionary) -> bool:
	return bool(frame.get("view_hold", false))


# --- 画布范围（棋盘逐帧缩放用）---

## 这一帧真正压在棋盘上的格子：棋子、高亮、箭头两端。
##
## 返回**紧凑范围**（不带外圈空白）；外圈是画布那一层的事（见 bounds_of）。
static func frame_bounds(frame: Dictionary) -> Rect2i:
	var min_cell := Vector2i(1 << 30, 1 << 30)
	var max_cell := Vector2i(-(1 << 30), -(1 << 30))
	var touched := false

	var groups: Array = [
		(frame.get("state", {}) as Dictionary).keys(),
		(frame.get("highlight", {}) as Dictionary).keys(),
	]
	for arrow in frame.get("arrows", []):
		groups.append([arrow["from"], arrow["to"]])
	for group in groups:
		for cell in group:
			var point: Vector2i = cell
			min_cell = Vector2i(mini(min_cell.x, point.x), mini(min_cell.y, point.y))
			max_cell = Vector2i(maxi(max_cell.x, point.x), maxi(max_cell.y, point.y))
			touched = true

	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE) if touched else Rect2i()


## 整段动画要用的**画布**范围（也就是「舞台」）——所有帧镜头的并集，再向外留一圈空白
## （已经贴着棋盘边的那侧不多留）。
##
## 作者给某一帧写了 `view` 时，这里**只用这些写死的视口**算并集：写小一点的视口不会让舞台跟着缩，
## 舞台只由最大的那个视口决定，所以「这一帧把镜头收窄了」表现出来是画面在舞台里变小，
## 而不是整块卡片跟着变尺寸。一帧都没写 view 时，走的就是原来的自动推导（见 canvas_of）。
##
## 画布按整段定死、不逐帧变：画布尺寸决定排版，它一变卡片里的文字就会跟着抖。
## 棋盘在画布内部逐帧缩放（见 GuideDemo 的 _shown_bounds）。
static func bounds_of(frames: Array, board_size: int = 0) -> Rect2i:
	# 没显式给棋盘边长时，用帧里带的那一个（build() 会写进去）
	if board_size <= 0:
		board_size = int((frames[0] as Dictionary).get("board_size", 7)) if not frames.is_empty() else 7
	if frames.is_empty():
		return Rect2i(Vector2i.ZERO, Vector2i(board_size, board_size))

	var min_cell := Vector2i(board_size, board_size)
	var max_cell := Vector2i(-1, -1)
	var touched := false
	for frame in frames:
		var frame_rect := view_of(frame)
		if frame_rect.size.x <= 0 or frame_rect.size.y <= 0:
			continue
		min_cell = Vector2i(
			mini(min_cell.x, frame_rect.position.x), mini(min_cell.y, frame_rect.position.y)
		)
		max_cell = Vector2i(
			maxi(max_cell.x, frame_rect.end.x - 1), maxi(max_cell.y, frame_rect.end.y - 1)
		)
		touched = true

	if not touched:
		return Rect2i(Vector2i.ZERO, Vector2i(board_size, board_size))

	if min_cell.x > 0:
		min_cell.x -= 1
	if min_cell.y > 0:
		min_cell.y -= 1
	if max_cell.x < board_size - 1:
		max_cell.x += 1
	if max_cell.y < board_size - 1:
		max_cell.y += 1
	# 夹回真实棋盘范围内这一步不能省：范围一旦越界，绘制层就会把棋盘画到画布外面
	min_cell = Vector2i(maxi(min_cell.x, 0), maxi(min_cell.y, 0))
	max_cell = Vector2i(mini(max_cell.x, board_size - 1), mini(max_cell.y, board_size - 1))
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)


## 这一整段要用的**舞台**大小（每个帧的镜头都得放得进它）。
##
## 与 bounds_of 的区别只有一处，也是作者写了 `view` 之后唯一会变的规矩：
##
##   * 有任意一帧写了 `view` → 舞台 = 这些视口尺寸的**最大值**（位置一律从 (0,0) 起算）。
##     视口比舞台小的帧，由绘制层**居中**放进去——所以改 view 的 x/y 是平移镜头，
##     改 w/h 是改变镜头张开的范围，舞台本身不会跳。
##   * 一帧都没写 `view` → 退回原来的自动推导（所有帧内容的并集 + 每侧留一圈，见 bounds_of）。
##
## 「舞台取最大」而不是「每个视口各算一个舞台」是刻意的：舞台尺寸一变，卡片里的文字排版
## 就会跟着重排、看起来在抖（这是踩过的坑，别再改成逐帧变）。
static func canvas_of(frames: Array, board_size: int = 0) -> Rect2i:
	if board_size <= 0:
		board_size = int((frames[0] as Dictionary).get("board_size", 7)) if not frames.is_empty() else 7
	var max_span := Vector2i.ZERO
	var has_explicit := false
	for frame in frames:
		if not has_view(frame):
			continue
		var rect := view_of(frame)
		has_explicit = true
		max_span = Vector2i(maxi(max_span.x, rect.size.x), maxi(max_span.y, rect.size.y))
	if not has_explicit:
		return bounds_of(frames, board_size)
	if max_span.x <= 0 or max_span.y <= 0:
		return Rect2i(Vector2i.ZERO, Vector2i(board_size, board_size))
	return Rect2i(Vector2i.ZERO, max_span)


# --- 读文件 ---

## 读 JSON。两条路都留着：
##   1. 直接读文件——开发时最直接，报错也只有我们自己的一条（json.parse 会给出错在哪一行）；
##   2. 退回资源加载——万一哪天它被当成资源打进包里（只有 load() 读得到）也还认。
static func _read_json(path: String) -> Variant:
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			var json := JSON.new()
			if json.parse(text) == OK:
				return json.data
			push_error("演示剧本 %s 第 %d 行解析失败：%s" % [path, json.get_error_line(), json.get_error_message()])
			return null
		push_error("演示剧本 %s 读出来是空的" % path)
		return null
	if ResourceLoader.exists(path):
		var res: Variant = ResourceLoader.load(path)
		if res is JSON and (res as JSON).data != null:
			return (res as JSON).data
	push_error("找不到演示剧本 %s：请在仓库根目录跑一次 python tools/export_guide_demos.py" % path)
	return null


# --- 解码：JSON → 绘制层要的帧 ---

## 把 JSON 里的**一段**剧本解成 `{caption, size, frames}`；读不出来的地方写进 `problems`
## （调用方拿它决定是整段跳过还是照用）。`load_demos` 与测试都走这里，所以「JSON 的键名」
## 与「build() 要的键名」这两层之间的翻译只有这一处（pieces→state、highlights→highlight、style→kind）。
static func decode_demo(raw: Variant, symbol: String, problems: Array) -> Dictionary:
	if not (raw is Dictionary):
		problems.append("这一段的写法不是一个对象")
		return {}
	var source: Dictionary = raw
	var size := int(source.get("size", 0))
	if size <= 0:
		problems.append("没有写 size（棋盘边长）")
		return {}
	var raw_frames: Variant = source.get("frames", [])
	if not (raw_frames is Array) or (raw_frames as Array).is_empty():
		problems.append("frames 是空的（一段动画至少要有一帧）")
		return {}

	var frames: Array = []
	for index in range((raw_frames as Array).size()):
		var where := "第 %d 帧" % [index + 1]
		var raw_frame: Variant = (raw_frames as Array)[index]
		if not (raw_frame is Dictionary):
			problems.append("%s 的写法不是一个对象" % where)
			continue
		frames.append(_decode_frame(raw_frame, size, where, problems))
	return {"caption": str(source.get("caption", "")), "size": size, "frames": frames}


static func _decode_frame(source: Dictionary, size: int, where: String, problems: Array) -> Dictionary:
	var state := {}
	var raw_pieces: Variant = source.get("pieces", {})
	if raw_pieces is Dictionary:
		for key in (raw_pieces as Dictionary).keys():
			var cell := _cell_key(str(key), size, "%s 的棋子" % where, problems)
			if cell.x < 0:
				continue
			var entry: Variant = (raw_pieces as Dictionary)[key]
			state[cell] = _piece_from_entry(entry, where, str(key), problems)
	elif not (raw_pieces is Dictionary):
		problems.append("%s 的 pieces 要写成 {\"x,y\": [兵种字, 阵营]}" % where)

	var highlight := {}
	var raw_highlights: Variant = source.get("highlights", [])
	if raw_highlights is Array:
		for item in (raw_highlights as Array):
			var cell := _point(item, size, "%s 的高亮格" % where, problems)
			if cell.x >= 0:
				highlight[cell] = HIGHLIGHT_LABEL

	var arrows: Array = []
	var raw_arrows: Variant = source.get("arrows", [])
	if raw_arrows is Array:
		for item in (raw_arrows as Array):
			if not (item is Dictionary):
				problems.append("%s 的箭头要写成 {from, to, style}" % where)
				continue
			var arrow: Dictionary = item
			var start := _point(arrow.get("from", []), size, "%s 箭头的 from" % where, problems)
			var end := _point(arrow.get("to", []), size, "%s 箭头的 to" % where, problems)
			var style := str(arrow.get("style", ARROW_STYLES[0]))
			if not (style in ARROW_STYLES):
				problems.append("%s 的箭头样式「%s」不认识（只能是 %s）" % [where, style, ", ".join(ARROW_STYLES)])
				style = ARROW_STYLES[0]
			if start.x < 0 or end.x < 0:
				continue
			arrows.append({"from": start, "to": end, "kind": style})

	var text := str(source.get("text", ""))
	if text.strip_edges().is_empty():
		problems.append("%s 没有写 text（空白帧就是观众只看到棋盘在动）" % where)

	var view := Rect2i()
	var raw_view: Variant = source.get("view")
	if raw_view != null:
		view = _view_rect(raw_view, size, where, problems)

	return {
		"state": state,
		"highlight": highlight,
		"arrows": arrows,
		"view": view,
		"view_hold": bool(source.get("view_hold", false)),
		"text": text,
		"hold": float(source.get("hold", 0.0)),
	}


## `[x, y, w, h]` → Rect2i。写坏了只报错并返回空（空 = 这一帧还是按内容自动推）。
static func _view_rect(value: Variant, size: int, where: String, problems: Array) -> Rect2i:
	if not (value is Array) or (value as Array).size() != 4:
		problems.append("%s 的 view 要写成 [x, y, 宽, 高]（左上角 + 格子数），收到 %s" % [where, str(value)])
		return Rect2i()
	var parts: Array = value
	for item in parts:
		if not _is_number(item):
			problems.append("%s 的 view 里有不是数字的项：%s" % [where, str(value)])
			return Rect2i()
	var origin := Vector2i(int(parts[0]), int(parts[1]))
	var span := Vector2i(int(parts[2]), int(parts[3]))
	if span.x <= 0 or span.y <= 0:
		problems.append("%s 的 view 宽高必须是正数（收到 %d×%d）——它是格子数，不是右下角坐标" % [
			where, span.x, span.y,
		])
		return Rect2i()
	if origin.x < 0 or origin.y < 0 or origin.x + span.x > size or origin.y + span.y > size:
		problems.append("%s 的 view [%d, %d, %d, %d] 超出了 %d×%d 棋盘" % [
			where, origin.x, origin.y, span.x, span.y, size, size,
		])
		return Rect2i()
	return Rect2i(origin, span)


static func _piece_from_entry(entry: Variant, where: String, key: String, problems: Array) -> PieceInfo:
	if not (entry is Array) or (entry as Array).size() != 2:
		problems.append("%s 的棋子 [%s] 要写成 [兵种字, 阵营]" % [where, key])
		return PieceInfo.new(PieceInfo.Kind.PAWN, PieceInfo.Camp.RED)
	var parts: Array = entry
	var symbol := str(parts[0])
	var kind: Variant = PieceInfo.SYMBOL_KINDS.get(symbol)
	if kind == null:
		problems.append("%s 的棋子字「%s」不认识" % [where, symbol])
		kind = PieceInfo.Kind.PAWN
	return PieceInfo.new(kind, _camp_of_name(str(parts[1]), where, problems))


static func _camp_of_name(name: String, where: String, problems: Array) -> PieceInfo.Camp:
	match name:
		"red":
			return PieceInfo.Camp.RED
		"green":
			return PieceInfo.Camp.GREEN
	problems.append("%s 的阵营「%s」不认识（只能是 red / green）" % [where, name])
	return PieceInfo.Camp.RED


# --- 小工具 ---

## `[x, y]` → Vector2i。越界只报错（不夹取）：夹取会把「棋盘写小了」这种错掩盖成画面正常。
static func _point(value: Variant, size: int, where: String, problems: Array) -> Vector2i:
	if not (value is Array) or (value as Array).size() != 2:
		problems.append("%s 要写成 [x, y]，收到 %s" % [where, str(value)])
		return Vector2i(-1, -1)
	var pair: Array = value
	if not _is_number(pair[0]) or not _is_number(pair[1]):
		problems.append("%s 的坐标不是数字：%s" % [where, str(value)])
		return Vector2i(-1, -1)
	var point := Vector2i(int(pair[0]), int(pair[1]))
	if not Rules.is_inside(point, size):
		problems.append("%s 的坐标 %s 落在 %d×%d 棋盘之外" % [where, point, size, size])
		return Vector2i(-1, -1)
	return point


static func _cell_key(text: String, size: int, where: String, problems: Array) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		problems.append("%s 的格子键「%s」不是 \"x,y\" 形式" % [where, text])
		return Vector2i(-1, -1)
	var point := Vector2i(int(parts[0]), int(parts[1]))
	if not Rules.is_inside(point, size):
		problems.append("%s 的格子 %s 落在 %d×%d 棋盘之外" % [where, point, size, size])
		return Vector2i(-1, -1)
	return point


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
