extends Node

## 指南里「动态图」的测试：不碰鼠标，所以可以 headless 跑。
##
## 演算层（GuideDemos）的每一项都必须和 rules.gd 对得上——本测试就是那个对账人：
## 它不写死「应该打哪一格」，而是拿真实的 Rules.attack_targets / resolve_kills 去核对
## 演示里的每一条弹道与每一次击杀，因此改了棋规却忘了改演示，这里会红。
##
## 运行：godot --headless --path <项目目录> res://tests/test_guide_demos.tscn
## 退出码 0 表示全部通过。

var _passed := 0
var _failed := 0
## _run() 全程跑完才会置为 true。中途因为脚本错误中断时它仍是 false，
## 这样就不会出现「测试半路挂了、却打印『失败 0 项』并返回 0」这种假通过。
var _completed := false


func _ready() -> void:
	await _run()
	if not _completed:
		printerr("测试没有跑完就中断了（多半是上面的 SCRIPT ERROR），按失败处理。")
		get_tree().quit(1)
		return
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	print("=== 指南演示（动态图）测试 ===")
	_test_every_note_has_demos()
	_test_timeline_matches_rules()
	_test_turn_durations()
	await _test_demo_bounds()
	await _test_bounds_transition_is_animated()
	_test_archer_demo_deterministic()
	await _test_demo_control_plays()
	_completed = true


# --- 用例 ---

## 每条棋子说明都该配一段演示。这个用例只检查「写了的演示是不是有效」，
## 没写演示的棋子只报告不判红——演示是逐张补的（现在只有弓）。
func _test_every_note_has_demos() -> void:
	print("-- 棋子说明与演示的对应关系 --")
	for note in PieceGuide.PIECE_NOTES:
		var kind: int = note["kind"]
		var symbol := PieceGuide.symbol_of(kind)
		var demos: Array = note.get("demos", [])
		_check(note.has("demos"), "「%s」有 demos 字段（现在 %d 段）" % [symbol, demos.size()])
		if demos.is_empty():
			print("  [跳过] 「%s」还没写演示" % symbol)
			continue
		for demo in demos:
			_check(
				not (demo.get("board", []) as Array).is_empty() and not (demo.get("phases", []) as Array).is_empty(),
				"「%s」的演示剧本有棋盘与阶段" % symbol
			)

	var archer: int = PieceInfo.Kind.ARCHER
	_check(
		not PieceGuide.demos_for(archer).is_empty(),
		"demos_for() 能取到弓的演示"
	)
	_check(
		PieceGuide.demos_for(PieceInfo.Kind.PAWN).is_empty(),
		"还没写演示的棋子返回空数组（不是报错）"
	)


## 核心用例：把每段演示的每一帧都拿 rules.gd 对一遍账。
func _test_timeline_matches_rules() -> void:
	print("-- 演示与 rules.gd 对账 --")
	for note in PieceGuide.PIECE_NOTES:
		for demo in note.get("demos", []):
			var frames := GuideDemos.build(demo)
			var symbol := PieceGuide.symbol_of(note["kind"])
			_check(not frames.is_empty(), "「%s」的演示能跑出帧（%d 帧）" % [symbol, frames.size()])
			if frames.is_empty():
				continue
			# 每一帧单独查：这样即使棋规变了、帧数变了，错误信息也能指出是哪一帧不对
			for index in range(frames.size()):
				_check_frame(note, demo, frames[index], index)
			# 再把整段时间轴串起来查一次：有阵亡就必须有对应的弹道
			var kills := _test_kills_come_from_shots(frames, symbol)
			_check(kills > 0, "「%s」的演示里确实打死了棋子（%d 枚）" % [symbol, kills])


## 一帧的自洽性检查：
##   1. 帧里的每一枚棋子都必须落在 Rules.camp_of 判定给它的半场；
##   2. 每一条弹道都必须真的在 Rules.attack_targets 的返回里
##      （例外：那条弹道自己指向的格子上站着敌方的盾——盾正是「挡住后面格子」的那一位，
##        它并不出现在攻击目标里，这是棋规里唯一一种「画了箭头但不算命中」的情况）。
func _check_frame(note: Dictionary, demo: Dictionary, frame: Dictionary, index: int) -> void:
	var label := "「%s」第 %d 帧" % [PieceGuide.symbol_of(note["kind"]), index]
	var state: Dictionary = frame["state"]
	var board_size := int((demo["board"] as Array).size())

	# 1. 势力与半场一致
	var misplaced := ""
	for cell in state.keys():
		var piece: PieceInfo = state[cell]
		if Rules.camp_of(cell, board_size) != piece.camp:
			misplaced = "%s 上的%s%s" % [cell, piece.camp_name(), piece.symbol()]
			break
	_check(misplaced == "", "%s：棋子都在自己半场（%s）" % [label, misplaced if misplaced != "" else "全部正确"])

	# 2. 弹道的起点必须真能打到终点
	for arrow in frame.get("arrows", []):
		if str(arrow.get("kind", "")) != "shot":
			continue
		var from: Vector2i = arrow["from"]
		var to: Vector2i = arrow["to"]
		var shooter: PieceInfo = state.get(from)
		if shooter == null:
			_check(false, "%s：弹道起点 %s 上没有棋子" % [label, from])
			continue
		var targets := Rules.attack_targets(state, from, shooter, board_size)
		if to in targets:
			_check(true, "%s：%s%s 打 %s 与 Rules 一致" % [label, shooter.camp_name(), shooter.symbol(), to])
			continue
		var victim: PieceInfo = state.get(to)
		var blocked := victim != null and victim.camp != shooter.camp \
			and victim.kind == PieceInfo.Kind.SHIELD \
			and Rules.is_shield_resisted(state, to, _direction(from, to), board_size)
		_check(blocked, "%s：%s 不被 Rules 认作 %s 的目标（%s）" % [
			label, shooter.symbol(), to, "盾挡住了弹道" if blocked else "而且它不是被抵抗的盾",
		])

	# 3. 阵亡帧里的棋子必须是**真的没了**：它已经不在这一帧的局面上。
	#    击杀帧不保留死者，是为了让画布能收回活着的棋子身上（见 GuideDemos._apply_shots），
	#    所以这里改成检查「死者确实消失了」；击杀集合本身由整段时间轴那个用例核对。
	for cell in frame.get("killed", []):
		_check(
			not state.has(cell),
			"%s：阵亡的 %s 已经从局面上移除（画布因此能收回来）" % [label, cell]
		)


## 整段时间轴上的击杀：每一个被杀掉的格子，都必须出现在**同一段剧本里某条弹道指向的目标**上。
##
## 单帧的击杀集合没法再用 Rules.resolve_kills 直接比对了——阵亡帧不保留死者
## （那是为了让画布收回来）。但那条线并没有松：弹道本身仍然逐帧对着
## Rules.attack_targets 验过，而这里要求「有击杀就必有对应的弹道」，
## 于是「击杀是凭规则打出来的」这件事依然被卡住。
func _test_kills_come_from_shots(frames: Array, symbol: String) -> int:
	var killed := {}
	var targets := {}
	for frame in frames:
		for cell in frame.get("killed", []):
			killed[cell] = true
		for arrow in frame.get("arrows", []):
			if str(arrow.get("kind", "")) == "shot":
				targets[arrow["to"]] = true

	var orphan := []
	for cell in killed.keys():
		if not targets.has(cell):
			orphan.append(cell)
	_check(
		orphan.is_empty(),
		"「%s」每一个阵亡的棋子都对应着一条弹道打过去（对不上的：%s）" % [
			symbol, orphan if not orphan.is_empty() else "无",
		]
	)
	return killed.size()


func _direction(from: Vector2i, to: Vector2i) -> Vector2i:
	var delta := to - from
	return Vector2i(signi(delta.x), signi(delta.y))


## 演示画布：整段范围定画布尺寸（不随帧变），棋盘在其中**逐帧缩放**。
## 这个用例守住整条链路：范围要覆盖必须看见的东西、不能越出真实棋盘、
## 每帧的紧凑范围要算对，而且「敌人的弹道指向哪，画布就得先长到哪」。
func _test_demo_bounds() -> void:
	print("-- 演示画布与逐帧缩放 --")
	for note in PieceGuide.PIECE_NOTES:
		for demo in note.get("demos", []):
			var frames := GuideDemos.build(demo)
			if frames.is_empty():
				continue
			var symbol := PieceGuide.symbol_of(note["kind"])
			var board_size := int((demo["board"] as Array).size())
			var bounds := GuideDemos.bounds_of(frames, board_size)

			# 1. 画布范围要把每一帧必须看见的每一格都包住
			var first_outside := ""
			for frame in frames:
				for cell in _visible_cells(frame):
					if not bounds.has_point(cell):
						first_outside = str(cell)
						break
				if first_outside != "":
					break
			_check(
				first_outside == "",
				"「%s」每一帧必须看见的格子都在画布范围内（越界的那格：%s）" % [
					symbol, first_outside if first_outside != "" else "无",
				]
			)

			# 2. 画布范围必须还在真实棋盘之内
			_check(
				bounds.position.x >= 0 and bounds.position.y >= 0 \
					and bounds.end.x <= board_size and bounds.end.y <= board_size,
				"「%s」画布范围 %s 没有超出 %d×%d 棋盘" % [symbol, bounds, board_size, board_size]
			)

			# 3. 比起整块棋盘，画布应该真的收窄了
			_check(
				bounds.size.x < board_size or bounds.size.y < board_size,
				"「%s」画布比整块棋盘小：%d×%d / %d×%d" % [
					symbol, bounds.size.x, bounds.size.y, board_size, board_size,
				]
			)

			# 4. 逐帧的紧凑范围：绝不能把必须看见的格子漏在外面
			var frame_outside := ""
			for frame in frames:
				var rect := GuideDemos.frame_bounds(frame)
				for cell in _visible_cells(frame):
					if not rect.has_point(cell):
						frame_outside = "%s（第 %d 帧）" % [cell, frames.find(frame)]
						break
				if frame_outside != "":
					break
			_check(
				frame_outside == "",
				"「%s」每一帧的紧凑范围都覆盖了该帧的元素（漏掉的：%s）" % [
					symbol, frame_outside if frame_outside != "" else "无",
				]
			)

	await _test_archer_scaling()


## 弓这一段的缩放节奏是需求钉死的：开局 4×4 → 击杀后 2×2 → 走子后 2×3。
func _test_archer_scaling() -> void:
	var frames := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	var sizes := PackedStringArray()
	for frame in frames:
		var rect := GuideDemos.frame_bounds(frame)
		sizes.append("%dx%d" % [rect.size.x, rect.size.y])

	_check(
		sizes[0] == "4x4",
		"开局棋盘是 4×4（两个炮架 2 格 + 弹道指向 2 格，加上外圈）（实际：%s）" % sizes[0]
	)
	_check(
		sizes[1] == "4x4",
		"开炮那一帧棋盘仍是 4×4——箭头的目标还在画面上（实际：%s）" % sizes[1]
	)
	_check(
		sizes[2] == "2x2",
		"两个敌人阵亡后棋盘收到 2×2（实际：%s）" % sizes[2]
	)
	_check(
		sizes[3] == "2x3" or sizes[3] == "3x2",
		"走子之后棋盘是 2×3（实际：%s）" % sizes[3]
	)
	_check(
		sizes[4] == sizes[3],
		"走子之后的范围一直保持到循环结束（实际：%s）" % sizes[4]
	)
	print("  逐帧范围：", " → ".join(sizes))

	# 控件里也要真的照着这个节奏走（goto_frame 会瞬间对准，不做过渡）
	var view := GuideDemo.new()
	add_child(view)
	view.set_frames(frames)
	var shown := PackedStringArray()
	for index in range(view.get_frame_count()):
		view.goto_frame(index)
		shown.append("%dx%d" % [int(view.get_shown_bounds().size.x), int(view.get_shown_bounds().size.y)])
	_check(
		" → ".join(shown) == " → ".join(sizes),
		"演示控件逐帧显示的范围与演算一致（实际：%s）" % " → ".join(shown)
	)

	# 画布（外框）本身不随帧变，否则卡片里的文字会跟着抖
	var canvas_size := view.custom_minimum_size
	for index in range(view.get_frame_count()):
		view.goto_frame(index)
		_check(
			view.custom_minimum_size.is_equal_approx(canvas_size),
			"第 %d 帧的画布尺寸没有变（%s）" % [index, view.custom_minimum_size]
		)
	view.queue_free()
	await get_tree().process_frame


## 每个回合演多久，由剧本的 duration 说了算：回合内部各帧按权重摊分，
## 加起来必须等于这个数。少了这条，「某个回合多了两帧就变得特别长」会悄悄发生。
func _test_turn_durations() -> void:
	print("-- 每个回合的时长 --")
	for note in PieceGuide.PIECE_NOTES:
		for demo in note.get("demos", []):
			var frames := GuideDemos.build(demo)
			if frames.is_empty():
				continue
			var symbol := PieceGuide.symbol_of(note["kind"])
			var declared := {}
			for phase in demo.get("phases", []):
				declared[str(phase.get("label", ""))] = float(phase.get("duration", 0.0))

			var actual := {}
			var order: Array = []
			for frame in frames:
				var label := str(frame.get("phase", ""))
				if not actual.has(label):
					actual[label] = 0.0
					order.append(label)
				actual[label] = float(actual[label]) + float(frame["hold"])

			for label in order:
				_check(
					declared.has(label) and declared[label] > 0.0,
					"「%s」回合「%s」声明了自己的时长" % [symbol, label]
				)
				if not declared.has(label):
					continue
				_check(
					is_equal_approx(float(actual[label]), declared[label]),
					"回合「%s」实际演 %.2f 秒，与声明的 %.2f 秒一致（%d 帧分摊）" % [
						label, float(actual[label]), declared[label],
						_count_frames_of(frames, label),
					]
				)

	# 弓这一段：每个回合都不该短到看不清，也不该长到让人等
	var archer_frames := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	var longest := 0.0
	var shortest := 1000.0
	for phase in PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0]["phases"]:
		var seconds := float(phase.get("duration", 0.0))
		longest = maxf(longest, seconds)
		shortest = minf(shortest, seconds)
	_check(
		shortest >= 1.2 and longest <= 3.0,
		"弓的三个回合都在 1.2~3.0 秒之间（实际 %.1f~%.1f 秒）" % [shortest, longest]
	)
	_check(
		is_equal_approx(shortest, longest),
		"弓的三个回合时长完全一样（每个 %.1f 秒）" % shortest
	)
	_check(
		archer_frames.size() > 0 and absf(archer_frames[0]["hold"] - 2.0) < 0.01,
		"开局那一帧就停 2.0 秒（实际 %.2f）" % archer_frames[0]["hold"]
	)


func _count_frames_of(frames: Array, label: String) -> int:
	var count := 0
	for frame in frames:
		if str(frame.get("phase", "")) == label:
			count += 1
	return count


## 缩放必须是**过渡**出来的，不能换帧时跳一下。
##
## 这条是防回归用的，针对的是一个真实踩过的坑：GDScript 给普通成员赋值**不会**触发重绘，
## 所以「Tween 在动、画面却停在过渡的第一帧」——看起来就是一次突变。
##
## 验证方式刻意不靠 `await process_frame` 采样：测试里一次 await 往往推进好几帧，
## 0.28 秒的过渡在两次采样之间就跑完了，采样看起来是突变的——那是测量的假象。
## 这里用 advance_bounds_for() 一次只推进固定的一小步，确定性地看到中间值。
func _test_bounds_transition_is_animated() -> void:
	print("-- 缩放是过渡出来的 --")
	var frames := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	var view := GuideDemo.new()
	add_child(view)
	view.custom_minimum_size = Vector2.ZERO
	view.size = Vector2(276, 314)
	view.set_frames(frames)
	await get_tree().process_frame

	# goto_frame 是「跳帧」，本来就该瞬间到位、不起过渡
	view.goto_frame(1)
	await get_tree().process_frame
	_check(
		not view.is_bounds_animating() and view.get_shown_bounds().size.x > 3.9,
		"跳帧是瞬间到位、不起过渡（实际 %s）" % view.get_shown_bounds().size
	)

	# 正常播放路径（_sync_bounds 不带 snap）必须起过渡
	view._sync_bounds(frames[2])
	_check(view.is_bounds_animating(), "范围一变（4×4 → 2×2）就起了过渡 Tween，不是直接赋值")

	var mid := view.advance_bounds_for(0.14)
	_check(
		mid.size.x < 3.99 and mid.size.x > 2.01,
		"过渡走到一半时范围确实是中间的（半程 %s）" % mid.size
	)

	var before := view.get_redraw_requests()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		view.get_redraw_requests() > before,
		"过渡途中还在持续请求重绘（%d → %d，画面不会冻在中间）" % [before, view.get_redraw_requests()]
	)

	view.advance_bounds_for(0.3)
	_check(
		view.get_shown_bounds().size.is_equal_approx(Vector2(2, 2)),
		"过渡走完正好落在 2×2（实际 %s）" % view.get_shown_bounds().size
	)

	# 反向也走一遍：2×2 → 4×4
	view._sync_bounds(frames[1])
	_check(view.is_bounds_animating(), "反向切回 4×4 同样起过渡")
	view.advance_bounds_for(0.3)
	_check(
		view.get_shown_bounds().size.is_equal_approx(Vector2(4, 4)),
		"再从 2×2 切回 4×4 也到位（实际 %s）" % view.get_shown_bounds().size
	)
	view.queue_free()
	await get_tree().process_frame


## 一帧里「必须看见」的格子：棋子、高亮、结算方与弹道两端。
## 刻意不含 moves（可走格小点）与正在阵亡的棋子——前者允许被裁掉，
## 后者正是「棋盘该收回来了」的信号。
func _visible_cells(frame: Dictionary) -> Array:
	var cells: Array = []
	for cell in (frame["state"] as Dictionary).keys():
		cells.append(cell)
	for key in ["attackers"]:
		for cell in frame.get(key, []):
			cells.append(cell)
	for cell in (frame["highlight"] as Dictionary).keys():
		cells.append(cell)
	for arrow in frame.get("arrows", []):
		cells.append(arrow["from"])
		cells.append(arrow["to"])
	return cells


## 同一段剧本跑两次必须得到同样的帧：演示是循环播放的，时间轴不能每次都变。
func _test_archer_demo_deterministic() -> void:
	print("-- 时间轴与开局的确定性 --")
	var demo: Dictionary = PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0]
	var first := GuideDemos.build(demo)
	var second := GuideDemos.build(demo)
	_check(str(first) == str(second), "同一段剧本两次演算得到完全一样的帧")

	# 开局局面必须和剧本上写的一字不差。这是最容易悄悄错的地方：
	# 手写棋盘会串位，而势力的归属由 Rules.camp_of 的反对角线决定——
	# (3,1) 看着靠右，其实 col+row = 4 < 6，仍在红方半场里。
	var state := GuideDemos.state_of(demo)
	_check(
		_state_signature(state) == "红弓(2,1) 红步(3,1) 绿步(5,1) 红步(2,2) 绿步(2,4)",
		"开局局面与剧本一致（实际：%s）" % _state_signature(state)
	)

	# 红弓同时借两个炮架：正交的 (3,1) 把弹道送到 (5,1)，斜向的 (2,2) 送到 (2,4)。
	var board_size := 7
	var targets := _sorted_cells(Rules.attack_targets(state, Vector2i(2, 1), state[Vector2i(2, 1)], board_size))
	_check(
		targets == "[(5, 1), (2, 4)]",
		"（2,1）的红弓同时打出两条弹道：(5,1) 正交 2 格、(2,4) 斜向 1 格（实际：%s）" % targets
	)
	# 炮架自己不会被误伤：它们不在目标里，红方的击杀也只有那两个绿步
	var red_kills := _sorted_cells(Rules.resolve_kills(state, board_size, PieceInfo.Camp.RED))
	_check(
		red_kills == "[(5, 1), (2, 4)]",
		"红方这一次结算只击杀两个绿步，没有误伤炮架（实际：%s）" % red_kills
	)
	# 绿步 (2,4) 会被抵抗吗？不会——is_shield_resisted 只管「盾」这一兵种
	# （步的对拼用的是另一套：比身后队列长度，见 Rules._pawn_targets）。
	_check(
		not Rules.is_shield_resisted(state, Vector2i(2, 1), Vector2i(0, 1), board_size),
		"弓背后有红步，但「抵抗」是盾的专属规则，弓身上不生效"
	)
	_check(
		Rules.resolve_kills(state, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"演示开局：绿方一发都打不出来"
	)

	# 走完一步之后：两个炮架的相对方位都变了，射程里再没有敌人
	var moved: Dictionary = state.duplicate()
	var archer: PieceInfo = moved[Vector2i(2, 1)]
	moved.erase(Vector2i(2, 1))
	moved.erase(Vector2i(5, 1))
	moved.erase(Vector2i(2, 4))
	moved[Vector2i(2, 0)] = archer
	var after := Rules.attack_targets(moved, Vector2i(2, 0), archer, board_size)
	_check(
		after.is_empty() and Rules.resolve_kills(moved, board_size, PieceInfo.Camp.RED).is_empty(),
		"红弓走到 (2,0) 后两个炮架都够不到人（实际：%s）" % _sorted_cells(after)
	)
	_check(
		Rules.resolve_kills(moved, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"走到 (2,0) 之后绿方也没有任何反击"
	)


## 把局面拼成「红弓(1,1) 红步(1,2) …」，按行、列排序，便于与剧本对账。
func _state_signature(state: Dictionary) -> String:
	var parts := PackedStringArray()
	for cell in _sorted(state.keys()):
		var piece: PieceInfo = state[cell]
		parts.append("%s%s(%d,%d)" % [piece.camp_name(), piece.symbol(), cell.x, cell.y])
	return " ".join(parts)


## 把一组格子排成稳定的字符串，便于直接和期望值比对。
func _sorted_cells(cells: Array) -> String:
	var parts := PackedStringArray()
	for cell in _sorted(cells):
		parts.append("(%d, %d)" % [cell.x, cell.y])
	return "[%s]" % ", ".join(parts)


## 按行、列把格子排序，让输出稳定（Dictionary 的键序不保证）。
func _sorted(cells: Array) -> Array:
	var copy: Array = cells.duplicate()
	copy.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x
	)
	return copy


## 演示控件本身：真实窗口/离屏都要能载入帧、能自动播、说明文字能跟着帧变。
func _test_demo_control_plays() -> void:
	print("-- 演示控件的播放 --")
	var view := GuideDemo.new()
	add_child(view)
	view.size = Vector2(320, 320)
	view.set_frames(GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0]))
	await get_tree().process_frame

	_check(view.get_frame_count() > 0, "控件载入了 %d 帧" % view.get_frame_count())
	_check(view.get_total_duration() > 0.0, "时间轴总长 %.1f 秒" % view.get_total_duration())
	_check(view.is_playing(), "载入后自动开始播放")
	_check(not view.get_current_frame().is_empty(), "当前帧不是空的")

	# 手动切到弹道那一帧，确认「这一帧真的在打人」，并且说明文字跟着换了
	var shot_index := _first_shot_frame(view)
	_check(shot_index >= 0, "时间轴里存在带弹道的帧")
	if shot_index >= 0:
		view.goto_frame(shot_index)
		var arrows: Array = view.get_current_frame()["arrows"]
		_check(arrows.size() > 0, "该帧画了 %d 条弹道" % arrows.size())
		_check(
			not view.get_status_text().is_empty(),
			"该帧有说明文字：%s" % view.get_status_text()
		)

	view.set_frames([])
	_check(view.get_frame_count() == 0, "传空帧列表不报错，只是什么都不画")
	view.queue_free()
	await get_tree().process_frame


func _first_shot_frame(view: GuideDemo) -> int:
	for index in range(view.get_frame_count()):
		view.goto_frame(index)
		for arrow in view.get_current_frame()["arrows"]:
			if str(arrow.get("kind", "")) == "shot":
				return index
	return -1


# --- 工具 ---

func _check(condition: bool, title: String) -> void:
	if condition:
		_passed += 1
		print("  [通过] %s" % title)
	else:
		_failed += 1
		printerr("  [失败] %s" % title)
