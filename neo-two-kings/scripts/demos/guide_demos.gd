class_name GuideDemos
extends RefCounted

## 指南里那些「动态图」的演算层：把一段声明式剧本跑成**帧列表**（纯数据，不含任何节点与绘制）。
##
## 为什么要有这一层：指南里画的每一条弹道、每一个击杀，都必须是 rules.gd 当场算出来的。
## 所以下面只做三件事——摆好剧本里的棋子、问 Rules「它能打谁 / 谁死了 / 能走到哪」、
## 把答案记进帧里。**这里不允许出现任何棋规判断**：一旦复制了棋规，改棋规时演示就会悄悄说谎。
##
## 帧结构（Dictionary）：
##   state      Dictionary[Vector2i -> PieceInfo]  该帧的局面（已死掉的棋子不在里面）
##   moves      Array[Vector2i]                    可走格（高亮小点）
##   arrows     Array[Dictionary]                  见 _step_arrow() / _shot()
##   killed     Array[Vector2i]                    本帧刚被击杀的格子（画成残影）
##   dead       Array[Vector2i]                    本帧为止已经死掉的格子（用于淡出）
##   highlight  Dictionary[Vector2i -> String]     剧本直接指定的格外高亮（例如王的 2x2 王区）
##   moves_text String                             走子阶段显示在棋盘下方的说明
##   text       String                             其余阶段显示在棋盘下方的说明
##   hold       float                              这一帧停留多久（秒），由 build() 按回合预算算出来
##
## 剧本结构（Dictionary）：
##   caption  一句话说明，画在棋盘下方
##   board    初始局面（用 board_from_cells 拼，别手写字符串）
##   phases   Array[Dictionary]，每项是 {label, duration, steps}：
##              duration  这一回合总共演多久（秒）。**必填**：
##                        回合里各帧分到多少时间，由 build() 按 _step_weight() 摊分，
##                        所以「每个回合持续多久」只在这一个地方说了算，
##                        不会因为某个回合多了两帧就变得特别长。
##              steps     每个 step 是 [类型, 权重, 参数]：
##                          ["move",   w, {from, to}]    走子
##                          ["shots",  w, {at}]          结算：由 Rules.attack_targets 出弹道、按轮播击杀
##                          ["zone",   w, {cells}]       只做格外高亮，不演算（王的王区、盾后那一格）
##                          ["expect", w, {text}]        只显示说明文字
##                        权重省略时按 _step_weight() 的默认值走。
##
## 时间轴是确定性的：同样的剧本永远得到同样的帧。

## 底部说明文字用的短标签。
const RED_LABEL := "红方"
const GREEN_LABEL := "绿方"
## 各 step 类型的默认权重，用来摊分回合时长。见 _step_weight()。
const DEFAULT_WEIGHT := 1.0
const BEAT_WEIGHT := 1.5
## 阵亡帧的权重：比一拍轻一点，但不能一闪而过。见 _apply_shots()。
const KILL_WEIGHT := 1.0


## 把剧本跑成帧列表。demo 为空字典时返回空数组。
##
## 时长在这里统一分配：每个回合先按自己的 duration 拿到一段时间，
## 再按回合内各帧的权重摊到每一帧上。这样「回合有多长」是剧本说了算的可读数字，
## 而不是散落在各处的 hold 常量拼出来的一笔糊涂账。
static func build(demo: Dictionary) -> Array:
	var frames: Array = []
	if demo.is_empty() or not demo.has("board"):
		return frames

	var state := state_of(demo)
	var dead := {}

	for phase in demo.get("phases", []):
		var begin := frames.size()
		# 回合标签写进每个 step：测试要按它把帧归回各自的回合，才好核对时长
		for raw_step in phase.get("steps", []):
			var step := _step(raw_step)
			step["label"] = str(phase.get("label", ""))
			match str(step["type"]):
				"move":
					_apply_move(frames, state, step)
				"shots":
					_apply_shots(frames, state, dead, step)
				_:
					# zone / expect 都只改显示，不动局面
					frames.append(_frame(state, dead, step, []))
		_distribute_duration(frames, begin, float(phase.get("duration", 0.0)))
	return frames


## 把 [begin, frames.size()) 这段帧的 hold 按权重摊到 phase_duration 秒上。
##
## 权重取自帧里记下的 "weight"（由 _step 从剧本抄进来，缺省见 _step_weight）。
## phase_duration 缺省（<= 0）时退回各帧自带的 hold，方便老剧本按帧写时长。
static func _distribute_duration(frames: Array, begin: int, phase_duration: float) -> void:
	if begin >= frames.size() or phase_duration <= 0.0:
		return
	var total := 0.0
	for index in range(begin, frames.size()):
		total += maxf(float(frames[index].get("weight", DEFAULT_WEIGHT)), 0.01)
	for index in range(begin, frames.size()):
		var share := maxf(float(frames[index].get("weight", DEFAULT_WEIGHT)), 0.01) / total
		frames[index]["hold"] = phase_duration * share


## 帧列表里出现过的、需要淡出的格子（已死的 + 正在死的）。
## 绘制层拿它决定哪枚棋子画成半透明，从而不必自己判断谁死了。
static func fading_cells(frames: Array) -> Dictionary:
	var fading := {}
	for frame in frames:
		for cell in frame["dead"]:
			fading[cell] = true
		for cell in frame["killed"]:
			fading[cell] = true
	return fading


## 这一帧真正压在棋盘上的格子：活着的棋子、弹道两端、格外高亮。
##
## 刻意**不含**三样东西：
##   ・moves（可走格小点）：弓一格能走八格，算上它范围立刻铺满两个棋盘。
##     它只是「能走到哪些空格」的辅助提示，允许被画布边缘裁掉。
##   ・正在阵亡的棋子与它的残影：敌人被打掉之后，画面就该收回到还活着的棋子身上——
##     「打完这一炮棋盘变小了」正是演示要传达的信息。
##
## 返回的是**紧凑范围**，不带外圈空白；外圈是画布那一层的事（见 bounds_of）。
static func frame_bounds(frame: Dictionary) -> Rect2i:
	var min_cell := Vector2i(1 << 30, 1 << 30)
	var max_cell := Vector2i(-(1 << 30), -(1 << 30))
	var touched := false

	var groups: Array = [
		(frame["state"] as Dictionary).keys(),
		(frame["highlight"] as Dictionary).keys(),
		frame.get("attackers", []),
	]
	# 弹道的两端：箭头指到哪，哪一格就得在画面上
	for arrow in frame["arrows"]:
		groups.append([arrow["from"], arrow["to"]])
	for group in groups:
		for cell in group:
			var point: Vector2i = cell
			min_cell = Vector2i(mini(min_cell.x, point.x), mini(min_cell.y, point.y))
			max_cell = Vector2i(maxi(max_cell.x, point.x), maxi(max_cell.y, point.y))
			touched = true

	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE) if touched else Rect2i()


## 整段演示要用的**画布**范围：所有帧的范围取并集，再向外留一圈空白。
##
## 为什么画布用并集、而不是逐帧跟着变：画布尺寸决定排版，它每帧都变的话，
## 卡片里的文字会跟着来回跳。所以画布按整段最大的那一次定死，
## 棋盘在里面逐帧缩放（见 frame_bounds 与 GuideDemo 的 _shown_bounds）。
##
## 已经贴着棋盘边的那一侧不再多留——那边本来就没有内容，留出来只是一条空行。
static func bounds_of(frames: Array, board_size: int = 7) -> Rect2i:
	if frames.is_empty():
		return Rect2i(Vector2i.ZERO, Vector2i(board_size, board_size))

	var min_cell := Vector2i(board_size, board_size)
	var max_cell := Vector2i(-1, -1)
	var touched := false
	for frame in frames:
		var frame_rect := frame_bounds(frame)
		if frame_rect.size.x <= 0:
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


# --- 各种 step 的处理 ---

## 走子：只问 Rules 这个落点合不合法。合法就落子，并把走子前可走的格子作为高亮记进帧里。
static func _apply_move(frames: Array, state: Dictionary, step: Dictionary) -> void:
	var from: Vector2i = step["from"]
	var to: Vector2i = step["to"]
	var mover: PieceInfo = state.get(from)
	if mover == null:
		push_error("演示剧本要在空格 %s 上走子" % [from])
		return

	var board_size := _board_size(state)
	var reachable := Rules.reachable_cells(state, from, board_size)
	if not (to in reachable):
		push_error("演示剧本要 %s 从 %s 走到 %s，但棋规不允许" % [mover.symbol(), from, to])

	# 高亮只写「为什么亮」，不写颜色：配色属于绘制层（guide_demo.gd）。
	var highlights := {}
	highlights[from] = "origin"
	for cell in step.get("inner", []):
		highlights[cell] = "zone"

	var frame := _frame(state, {}, step, [])
	frame["moves"] = reachable
	frame["highlight"] = highlights
	frame["arrows"] = [_step_arrow(from, to)]
	frame["moves_text"] = str(step.get("moves_text", ""))
	frame["text"] = str(step.get("text", ""))
	frames.append(frame)

	state.erase(from)
	state[to] = mover


## 结算：弹道由 Rules.attack_targets 逐个给出，击杀由 Rules.resolve_rounds 逐轮给出。
## 两者都从 rules.gd 来，所以演示里不会出现「文案说打得到、演算却打不到」这种偏差。
static func _apply_shots(frames: Array, state: Dictionary, dead: Dictionary, step: Dictionary) -> void:
	var at: Vector2i = step["at"]
	var piece: PieceInfo = state.get(at)
	if piece == null:
		push_error("演示剧本要在空格 %s 上结算攻击" % [at])
		return
	var board_size := _board_size(state)

	var arrows: Array = []
	for target in Rules.attack_targets(state, at, piece, board_size):
		arrows.append(_shot(at, target, piece))

	var round_kills: Array = []
	for round_targets in Rules.resolve_rounds(state, board_size, piece.camp):
		round_kills.append(round_targets)

	var hit_text := str(step.get("text", ""))
	if arrows.is_empty():
		hit_text = str(step.get("none_text", hit_text))

	# 先出一帧「弹道」，再按轮出一帧「阵亡」：连锁的先后顺序因此看得见。
	var shot_frame := _frame(state, dead, step, [])
	shot_frame["arrows"] = arrows
	shot_frame["moves_text"] = str(step.get("moves_text", ""))
	shot_frame["text"] = hit_text
	frames.append(shot_frame)

	for index in range(round_kills.size()):
		var killed: Array[Vector2i] = round_kills[index]
		# 这一轮死掉的棋子从局面上移除，残影交给 fading_cells 去淡出。
		#
		# 注意顺序：先把它们从 state 里拿掉、再快照这一帧。这样「阵亡帧」才是干净的
		# ——没有弹道、没有敌人，画布于是收回活着的棋子身上，
		# 「打完这一炮棋盘变小了」才看得出来。
		#
		# 代价是这一帧不能再用 Rules.resolve_kills 直接校验击杀集合
		# （局面已经不含死者）。所以测试改成校验整段时间轴的击杀并集
		# ——每一个被杀的格子都出现在同一段剧本的某个弹道目标里，
		# 而那个目标本身仍然是逐帧对着 Rules.attack_targets 验过的。
		for cell in killed:
			state.erase(cell)
			dead[cell] = true
		var kill_frame := _frame(state, dead, step, killed)
		kill_frame["moves_text"] = str(step.get("moves_text", ""))
		if round_kills.size() > 1:
			kill_frame["text"] = "第 %d 轮：%s" % [index + 1, str(step.get("kill_text", hit_text))]
		else:
			kill_frame["text"] = str(step.get("kill_text", hit_text))
		kill_frame["dead"] = dead.keys().duplicate()
		# 阵亡帧不必和「打一炮」一样重，但也不能一闪而过：权重调低一档，
		# 让看的人来得及注意到棋盘收回来了。
		kill_frame["weight"] = KILL_WEIGHT
		frames.append(kill_frame)


# --- 帧构造 ---

## 造一帧。attackers 是这一帧要发光的格子（结算方）。
##
## hold 先按权重占个位，真正的时长由 build() 在回合结束时统一摊分（见 _distribute_duration）。
static func _frame(state: Dictionary, dead: Dictionary, step: Dictionary, killed: Array) -> Dictionary:
	var highlight := {}
	var declared: Variant = step.get("highlight", {})
	if declared is Dictionary:
		for cell in declared:
			highlight[cell] = declared[cell]
	return {
		"state": state.duplicate(),
		"moves": [],
		"arrows": [],
		"attackers": step.get("attackers", []).duplicate(),
		"killed": killed.duplicate(),
		"dead": dead.keys().duplicate(),
		"highlight": highlight,
		"moves_text": "",
		"text": "",
		"hold": 0.0,
		"weight": float(step.get("weight", DEFAULT_WEIGHT)),
		"phase": str(step.get("label", step.get("phase", ""))),
	}


## 剧本里一个 step 的规范化：短的写成数组，长的写成字典，这里统一成字典。
##
## 数组形式 [类型, 权重, 参数] 里的第二个元素是**权重**（不是秒数）：
## 具体多少秒由它所在回合的 duration 按权重摊出来。
## 权重省略时按类型给个默认值——「打一炮」「走一步」这种动作位的权重高一点，
## 因为它才是这一步的重点；纯文字帧和阵亡帧权重低，快一点过去。
static func _step(raw: Variant) -> Dictionary:
	var step := {
		"type": "expect",
		"phase": "",
		"text": "",
		"moves_text": "",
		"highlight": {},
		"attackers": [],
		"inner": [],
	}
	if raw is Array:
		var parts: Array = raw
		if parts.size() > 0:
			step["type"] = str(parts[0])
		if parts.size() > 1:
			step["weight"] = float(parts[1])
		if parts.size() > 2 and parts[2] is Dictionary:
			for key in parts[2]:
				step[key] = parts[2][key]
	elif raw is Dictionary:
		for key in raw:
			step[key] = raw[key]
	if not step.has("weight"):
		step["weight"] = _step_weight(str(step["type"]))
	return step


## 某个 step 缺省该占多重。见 _step 的说明。
static func _step_weight(kind: String) -> float:
	return BEAT_WEIGHT if kind == "move" or kind == "shots" else DEFAULT_WEIGHT


# --- 剧本 / 棋盘 ---

## 用「格子 → 棋子字」拼出一副棋盘。
##
## 手写棋盘字符串（像 Session.INITIAL_LAYOUT 那样）最容易犯的错是某一行少数或多数一个
## 字符，于是整行棋子串位、而画面上看着还挺正常。演示棋盘因此不手写，一律用它拼出来。
static func board_from_cells(cells: Dictionary, board_size: int = 7) -> Array:
	var grid: Array = []
	for _row in range(board_size):
		grid.append(Session.EMPTY_SYMBOL.repeat(board_size))
	var placed := 0
	for cell in cells.keys():
		var point: Vector2i = cell
		if point.x < 0 or point.y < 0 or point.x >= board_size or point.y >= board_size:
			push_error("演示棋盘上的 %s 落在 %d×%d 之外" % [point, board_size, board_size])
			continue
		var symbol := str(cells[cell])
		if symbol.length() != 1:
			push_error("演示棋盘上 %s 的棋子字「%s」不是一个字" % [point, symbol])
			continue
		var line := str(grid[point.y])
		grid[point.y] = line.substr(0, point.x) + symbol + line.substr(point.x + 1)
		placed += 1
	if placed != cells.size():
		push_error("演示棋盘有 %d 个格子没摆上，实际摆了 %d 个" % [cells.size() - placed, placed])
	return grid


## 剧本 → 初始局面（也供测试对账用）。势力按 Rules.camp_of 判定，和真实开局同一条规则，
## 所以演示里不可能出现「红方棋子被摆在绿方半场」这种和规则不符的设定。
##
## 棋盘每行必须一样长（也就是正方形）：万一有人还是手写了棋盘，这里替他拦住串位。
static func state_of(demo: Dictionary) -> Dictionary:
	var layout: Array = demo["board"]
	var board_size := layout.size()
	var result := {}
	for row in range(board_size):
		var line := str(layout[row])
		if line.length() != board_size:
			push_error("演示剧本第 %d 行有 %d 个字，棋盘需要 %d 个" % [row, line.length(), board_size])
			continue
		for col in range(board_size):
			var symbol := line[col]
			if symbol == Session.EMPTY_SYMBOL:
				continue
			if not PieceInfo.SYMBOL_KINDS.has(symbol):
				push_error("演示剧本第 %d 行出现未知棋子符号「%s」" % [row, symbol])
				continue
			var cell := Vector2i(col, row)
			result[cell] = PieceInfo.new(PieceInfo.SYMBOL_KINDS[symbol], Rules.camp_of(cell, board_size))
	return result


static func _board_size(state: Dictionary) -> int:
	var size := 0
	for cell in state.keys():
		size = maxi(size, maxi(cell.x, cell.y) + 1)
	# 局面里可能全是低坐标的棋子，棋盘边长按剧本给的行数更可靠；
	# 这里保证至少放得下每一个棋子，且不小于 2（王区计算需要）。
	return maxi(size, 2)


# --- 箭头 / 标签 ---

## 走子箭头。
static func _step_arrow(from: Vector2i, to: Vector2i) -> Dictionary:
	return {"from": from, "to": to, "kind": "move", "text": ""}


## 一条弹道。kind 用兵种名，绘制层据此选线型；text 是描述，不带任何数量（数量由调用方数出来）。
static func _shot(from: Vector2i, to: Vector2i, piece: PieceInfo) -> Dictionary:
	return {
		"from": from,
		"to": to,
		"kind": "shot",
		"text": "%s%s" % [_camp_label(piece.camp), piece.symbol()],
	}


## 剧本里直接写死的一个格子标记（王的王区、盾后那一格等）。这些不是演算结果，
## 因为「哪一格是王区」在 Rules.king_area 里已经有权威答案，演示只是把它画出来。
static func zone_arrow(from: Vector2i, to: Vector2i, text: String) -> Dictionary:
	return {"from": from, "to": to, "kind": "zone", "text": text}


static func _camp_label(camp: PieceInfo.Camp) -> String:
	return RED_LABEL if camp == PieceInfo.Camp.RED else GREEN_LABEL
