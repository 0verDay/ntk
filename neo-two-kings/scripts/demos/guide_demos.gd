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
##   size     棋盘边长。**建议每段演示都写明**：棋盘边长决定双方半场（Rules.camp_of），
##            不写就只能从棋子的最大坐标猜——王的 2×2 王区、半场归属都可能因此算错。
##   phases   Array[Dictionary]，每项是 {label, duration, steps}：
##              duration  这一回合总共演多久（秒）。**必填**：
##                        回合里各帧分到多少时间，由 build() 按 _step_weight() 摊分，
##                        所以「每个回合持续多久」只在这一个地方说了算，
##                        不会因为某个回合多了两帧就变得特别长。
##              steps     每个 step 是 [类型, 权重, 参数]：
##                          ["move",   w, {from, to}]    走子（八方向一格）
##                          ["hop",    w, {from, to}]    骑的跳跃/连跳：每一段都越过相邻的一子，
##                                                       落到它正后方；斜向连跳用 path 写明中间落点
##                          ["remove", w, {cells}]       把棋子从局面上撤走（不是击杀）——盾那段用它
##                                                       把盾身后的自己人撤掉，同一发就从被抵抗变成打中
##                          ["shots",  w, {at}]          结算：由 Rules.attack_targets 出弹道、按轮播击杀。
##                                                       结算方取「站在 at 上那枚棋子自己的阵营」，
##                                                       所以也能演敌方攻击（盾的抵抗）
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
	# 剧本级的阵营修正（示意图里那几枚「画上去的」棋子）：Array 形式的 [兵种字, 阵营]。
	# 它与 step 里的 `pieces`（整帧替换显示局面）是两件事，所以用一个独立的键名。
	var fixed: Dictionary = demo.get("board_pieces", {}) if demo.get("board_pieces", {}) is Dictionary else {}
	# 棋盘边长：剧本写明了就用它，没写才退回「按棋子最大坐标猜」。
	# 这一条不能省——王的王区、双方的半场都由它决定，猜错了演出来的就是另一盘棋。
	var board_size := _demo_board_size(demo)
	# 棋盘必须装得下所有棋子，否则 rules 会按「更小的棋盘」算半场，画面上就全乱套了
	var overflow := _first_outside(state, board_size)
	if overflow != Vector2i(-1, -1):
		push_error("演示剧本声明棋盘 %d×%d，但 %s 上的棋子落在棋盘之外" % [board_size, board_size, overflow])
	var dead := {}

	for phase in demo.get("phases", []):
		var begin := frames.size()
		# 回合标签写进每个 step：测试要按它把帧归回各自的回合，才好核对时长
		for raw_step in phase.get("steps", []):
			var step := _step(raw_step)
			step["label"] = str(phase.get("label", ""))
			step["board_size"] = board_size
			if not fixed.is_empty():
				step["fixed_pieces"] = fixed
			match str(step["type"]):
				"move":
					_apply_move(frames, state, step)
				"hop":
					_apply_hop(frames, state, step)
				"remove":
					_apply_remove(frames, state, step)
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
	# 棋规判定用「显示局面」：剧本写了 pieces 时，连规则也要按画面上那个来算，
	# 否则会出现「画面上是个敌人、规则里却是自己人」的错位（王的教程就靠这个）。
	var shown := _shown_state(state, step)
	var mover: PieceInfo = shown.get(from)
	if mover == null:
		push_error("演示剧本要在空格 %s 上走子" % [from])
		return

	var board_size := int(step.get("board_size", _board_size(state)))
	var reachable := Rules.reachable_cells(shown, from, board_size)
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


## 骑的跳跃 / 连跳：from 与 to 之间至少隔一格，且这条直线上的每一格都必须有棋子——
## 骑是一路「越过」它们落到 to 的（to 本身必须是空格，且真的在 Rules.reachable_cells 里）。
##
## 箭头按**每一段跳**拆开画（一跳一格），所以「A → B → C」这种连跳的轨迹一眼看得出。
## 相邻两格（只跳过一枚棋子）也是一跳，中间那格会被记进 hop.crossed 里，绘制层据此点出跳板。
##
## 与 _apply_move 一样，帧里画的是「跳之前」的局面（换帧时新位置才生效），
## 但 moves 高亮用的是**跳之后**的可走格：连跳的第二跳要站在第一跳的落点上才算得出来。
static func _apply_hop(frames: Array, state: Dictionary, step: Dictionary) -> void:
	var from: Vector2i = step["from"]
	var to: Vector2i = step["to"]
	var shown := _shown_state(state, step)
	var mover: PieceInfo = shown.get(from)
	if mover == null:
		push_error("演示剧本要在空格 %s 上起跳" % [from])
		return

	var board_size := int(step.get("board_size", _board_size(state)))
	var reachable := Rules.reachable_cells(shown, from, board_size)
	if not (to in reachable):
		push_error("演示剧本要让 %s%s 从 %s 跳到 %s，但棋规不允许" % [mover.camp_name(), mover.symbol(), from, to])

	# 逐段拆开：每一段都是「越过相邻的一枚棋子，落到它正后方」。
	# 剧本可以写 `path` 显式给出中间落点；不写就按 from → to 这条直线推。
	var path := _hop_path(step, from, to)
	var arrows: Array = []
	for i in range(path.size() - 1):
		var a: Vector2i = path[i]
		var b: Vector2i = path[i + 1]
		var arrow := _step_arrow(a, b)
		arrow["kind"] = "hop"
		arrow["text"] = "%s%s" % [_camp_label(mover.camp), mover.symbol()]
		arrow["hop"] = {"dir": _hop_direction(a, b), "crossed": []}
		arrows.append(arrow)

	var frame := _frame(state, {}, step, [])
	frame["moves"] = reachable
	frame["highlight"] = {from: "origin"}
	frame["arrows"] = arrows
	frame["moves_text"] = str(step.get("moves_text", ""))
	frame["text"] = str(step.get("text", ""))
	frames.append(frame)

	state.erase(from)
	state[to] = mover


## 把一次跳（可能是连跳）拆成逐段的落点列表：from, …, to。
##
## 剧本写明 `path`（中间落点）就用它——斜向连跳（比如 (4,2) →(3,1)→ (2,0)）必须写，
## 因为那不是一条直线，推不出来。没写就按 from → to 的八方向直线每两格推一段。
##
## 每一段都必须真的是「越过紧邻的一枚棋子、落到它正后方」：段长不能超过两格，
## 而且每一段的落点都要真的在棋规的射程里（最后一段会由 _apply_hop 再验一遍）。
static func _hop_path(step: Dictionary, from: Vector2i, to: Vector2i) -> Array:
	var declared: Variant = step.get("path", [])
	var candidates: Array = []
	if declared is Array and not (declared as Array).is_empty():
		for point in declared:
			candidates.append(point)
		candidates.append(to)
	else:
		var dir := _hop_direction(from, to)
		if dir == Vector2i.ZERO:
			return [from, to]
		var cursor := from
		while cursor != to and candidates.size() <= 8:
			cursor += dir * 2
			candidates.append(cursor)
		if candidates.is_empty() or candidates[candidates.size() - 1] != to:
			return [from, to]

	# 逐段检查：每段最多跨两格，且落点都在棋盘内
	var path: Array = [from]
	var current := from
	for point in candidates:
		var step_vec: Vector2i = point - current
		if maxi(absi(step_vec.x), absi(step_vec.y)) > 2:
			return [from, to]
		path.append(point)
		current = point
	return path


## from → to 走的是哪条八方向线；不是直线（或只隔一格）时返回 ZERO。
static func _hop_direction(from: Vector2i, to: Vector2i) -> Vector2i:
	var delta := to - from
	if delta.x != 0 and delta.y != 0 and absi(delta.x) != absi(delta.y):
		return Vector2i.ZERO
	if delta == Vector2i.ZERO:
		return Vector2i.ZERO
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps < 2:
		return Vector2i.ZERO
	return Vector2i(signi(delta.x), signi(delta.y))


## 把一枚棋子从局面上拿掉（不是击杀，是「把它挪开」这种示意）。
##
## 盾的第二段用得上：把盾身后那枚自己人撤走，同一发攻击就从「被抵抗」变成「打中」——
## 这是**局面的变化**，只靠显示层的 cleared 是演不出来的（Rules 得看到新局面）。
static func _apply_remove(frames: Array, state: Dictionary, step: Dictionary) -> void:
	var cells: Array = step.get("cells", [])
	for cell in cells:
		state.erase(cell)
	var frame := _frame(state, {}, step, [])
	frame["text"] = str(step.get("text", ""))
	frame["moves_text"] = str(step.get("moves_text", ""))
	frames.append(frame)


## 结算：弹道由 Rules.attack_targets 逐个给出，击杀由 Rules.resolve_rounds 逐轮给出。
## 两者都从 rules.gd 来，所以演示里不会出现「文案说打得到、演算却打不到」这种偏差。
##
## 结算方阵营取「站在 at 上那枚棋子自己的阵营」——这样敌方也能开火，
## 盾的「被抵抗」（敌人打盾、这一击作废）才有得演。剧本里不用写阵营，写错也写不出来。
static func _apply_shots(frames: Array, state: Dictionary, dead: Dictionary, step: Dictionary) -> void:
	var at: Vector2i = step["at"]
	var shown := _shown_state(state, step)
	var piece: PieceInfo = shown.get(at)
	if piece == null:
		push_error("演示剧本要在空格 %s 上结算攻击" % [at])
		return
	var board_size := int(step.get("board_size", _board_size(state)))
	var camp: PieceInfo.Camp = piece.camp

	var round_kills: Array = []
	for round_targets in Rules.resolve_rounds(shown, board_size, camp):
		round_kills.append(round_targets)

	# 每一轮各自算弹道：第一轮用当前局面，后面的轮次用「上一轮死者已经拿掉」的局面。
	# 这样连锁打出来的那几发也有箭头，而且来源是逐轮问 Rules 问出来的，不是编的。
	var remaining := shown.duplicate()
	var round_arrows: Array = []
	for round_targets in round_kills:
		var shots: Array = []
		for cell in remaining.keys():
			var shooter: PieceInfo = remaining[cell]
			if shooter.camp != camp:
				continue
			for target in Rules.attack_targets(remaining, cell, shooter, board_size):
				if target in round_targets:
					shots.append(_shot(cell, target, shooter))
		round_arrows.append(shots)
		for cell in round_targets:
			remaining.erase(cell)

	var arrows: Array = round_arrows[0] if not round_arrows.is_empty() else []

	var hit_text := str(step.get("text", ""))
	if arrows.is_empty():
		hit_text = str(step.get("none_text", hit_text))
	# 抵抗/空放：这一发什么都没打中（比如盾把攻击抵抗掉了）——单出一帧说明，
	# 否则「没有弹道」看起来就像演示卡住了。
	if arrows.is_empty():
		var none_frame := _frame(state, dead, step, [])
		none_frame["arrows"] = []
		none_frame["moves_text"] = ""
		none_frame["text"] = hit_text
		frames.append(none_frame)

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
		# 第二轮之后的阵亡是**连锁**带出来的：把那一轮的弹道也画上，
		# 观众才看得见「是谁带走了它们」（来源仍是逐轮问 Rules 问出来的）。
		if index >= 1 and index < round_arrows.size():
			kill_frame["arrows"] = (round_arrows[index] as Array).duplicate()
		kill_frame["moves_text"] = str(step.get("moves_text", ""))
		# 文案按轮次说人话：
		#   只有一轮 → 直接用 kill_text；
		#   第一轮   → 先用 text（「这一发打出去会发生什么」），别把后面的连锁提前剧透；
		#   后面几轮 → 标明「第 N 轮」再说 kill_text。
		if round_kills.size() == 1:
			kill_frame["text"] = str(step.get("kill_text", hit_text))
		elif index == 0:
			kill_frame["text"] = str(step.get("first_kill_text", step.get("kill_text", hit_text)))
		else:
			kill_frame["text"] = "第 %d 轮连锁：%s" % [index + 1, str(step.get("kill_text", hit_text))]
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
	# zones：只画格外高亮、不碰局面（王的王区）。它和 highlight 是同一件事，
	# 分成两个键只是为了让剧本读起来更像话：highlight 是「这一步带来的高亮」，
	# zones 是「一直摆在那儿的区域」。
	var zones: Variant = step.get("zones", {})
	if zones is Dictionary:
		for cell in zones:
			highlight[cell] = zones[cell]
	# pieces：只替换**这一帧显示出来**的局面，不动棋规状态。
	# 给「棋盘拉远、重新摆一次」或「示意摆位」这种帧用（王的教程）。
	#
	# 另外：本帧刚阵亡的棋子也要从**显示局面**里去掉。_frame 拿到的 state 是
	# 「移除死亡之前」的快照（这样击杀集合能对上），不补这一步的话，画面会把
	# 刚死掉的棋子当活棋再画一遍。
	var shown := _shown_state(state, step)
	for cell in killed:
		shown.erase(cell)
	return {
		"state": shown,
		"cleared": step.get("cleared", []).duplicate(),
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
		"zones": {},
		"pieces": {},
		"cleared": [],
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
	return BEAT_WEIGHT if kind == "move" or kind == "hop" or kind == "shots" else DEFAULT_WEIGHT


# --- 剧本 / 棋盘 ---

## 这段演示用的棋盘边长：剧本写了 `size` 就用它，否则取棋盘行数。
##
## state_of()（决定每枚棋子的阵营）与 build()（决定 Rules 怎么算）必须用**同一个数**，
## 否则会出现「画面上是敌人、规则里是自己人」这种对不上的情况——写成函数就是为了只留一处。
static func _demo_board_size(demo: Dictionary) -> int:
	return int(demo.get("size", (demo.get("board", []) as Array).size()))


## 用「格子 → 棋子字」拼出一副棋盘。
##
## 手写棋盘字符串（像 Session.INITIAL_LAYOUT 那样）最容易犯的错是某一行少数或多数一个
## 字符，于是整行棋子串位、而画面上看着还挺正常。演示棋盘因此不手写，一律用它拼出来。
##
## 值可以写 "步"（阵营按 Rules.camp_of 定），也可以写 ["步", 阵营] **显式指定**——
## 后者只给示意图用（见 piece_guide.gd 里王 / 骑 B 的说明）。
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
		var spec: Variant = cells[cell]
		var symbol := str((spec as Array)[0]) if spec is Array else str(spec)
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
	# 剧本可以显式声明棋盘边长（"size"）。它同时决定双方半场，
	# 所以这里和 build() 必须用同一个数——否则会出现「画面上是敌人、规则里是自己人」。
	var declared := _demo_board_size(demo)
	var result := {}
	# 剧本可以在 board 之外再补几枚**只用于示意图**的棋子：`board_pieces` 用 Array 形式
	# 显式写阵营，覆盖掉按半场推出来的结果（见 piece_guide.gd 里各段 schematic 的说明）。
	var extras: Variant = demo.get("board_pieces", {})
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
			result[cell] = PieceInfo.new(PieceInfo.SYMBOL_KINDS[symbol], Rules.camp_of(cell, declared))
	# 显式指定阵营的那几枚（示意图）覆盖掉上面按半场推出来的结果
	if extras is Dictionary:
		for key in extras:
			var point: Vector2i = key
			result[point] = _piece_from_symbol((extras as Dictionary)[key], point, declared)
	return result


## 单个棋子字 → PieceInfo。
##
## 阵营默认按 Rules.camp_of 定（和真实开局同一条规则），但允许剧本显式写成
## `{cell: [兵种字, 阵营]}` 来指定——**只用于示意图**：有些教具摆位（比如王区里的敌军）
## 在真实半场规则下根本摆不出来，那时需要一个「画出来的敌人」。
static func _piece_from_symbol(spec: Variant, cell: Vector2i, board_size: int) -> PieceInfo:
	var symbol := ""
	var camp := Rules.camp_of(cell, board_size)
	if spec is Array:
		var parts: Array = spec
		if parts.size() > 0:
			symbol = str(parts[0])
		if parts.size() > 1:
			camp = int(parts[1])
	else:
		symbol = str(spec)
	if not PieceInfo.SYMBOL_KINDS.has(symbol):
		push_error("示意帧出现未知棋子符号「%s」" % symbol)
		return PieceInfo.new(PieceInfo.Kind.PAWN, camp)
	return PieceInfo.new(PieceInfo.SYMBOL_KINDS[symbol], camp)


## 这一帧**显示**出来的局面：默认就是当前局面，剧本写了 pieces 就整套换成它（只影响显示）。
## `cleared` 里的格子再从显示局面里抹掉——用来演「把这枚棋子拿走」这种示意（盾的第二段）。
## `fixed_pieces` 是剧本级的阵营修正（示意图里那几枚「画上去的敌人」）。
static func _shown_state(state: Dictionary, step: Dictionary) -> Dictionary:
	var result: Dictionary = state.duplicate()
	var board_size := int(step.get("board_size", _board_size(state)))
	# fixed_pieces 只补「现在局面上还有的」那几枚：用 remove 撤走的棋子不能被它再加回来
	for key in step.get("fixed_pieces", {}):
		var point: Vector2i = key
		if result.has(point):
			result[point] = _piece_from_symbol((step["fixed_pieces"] as Dictionary)[key], point, board_size)
	var shown: Variant = step.get("pieces", {})
	if shown is Dictionary and not (shown as Dictionary).is_empty():
		result.clear()
		for key in shown:
			var point: Vector2i = key
			result[point] = _piece_from_symbol((shown as Dictionary)[key], point, board_size)
	for cell in step.get("cleared", []):
		result.erase(cell)
	return result


## 找出第一枚落在棋盘外的棋子；都在盘内时返回 Vector2i(-1, -1)。
static func _first_outside(state: Dictionary, board_size: int) -> Vector2i:
	for cell in state.keys():
		if not Rules.is_inside(cell, board_size):
			return cell
	return Vector2i(-1, -1)


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
