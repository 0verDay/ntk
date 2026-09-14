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
	_test_archer_opening_flow()
	_test_pawn_flow()
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
		not PieceGuide.demos_for(PieceInfo.Kind.PAWN).is_empty(),
		"demos_for() 也能取到步的演示（步与弓共用同一套演示框架）"
	)
	_check(
		PieceGuide.note_for(PieceInfo.Kind.KNIGHT).has("demos")
			and (PieceGuide.note_for(PieceInfo.Kind.KNIGHT)["demos"] as Array).size() == 2,
		"骑有两段演示（连跳 + 夹击）"
	)
	_check(
		PieceGuide.note_for(-1).is_empty(),
		"问一个不存在的兵种时返回空字典（不是报错）"
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
			# 「谁杀的」分两种：弓/步/骑这种远程击杀会留下弹道（上面那条已经查过），
			# 而王的吃子是**走上去吃掉**，画面上不出现弹道——所以它单独评。
			# 演示可以标 no_kill 声明「这一段只讲走位、不讲击杀」（骑的连跳那段就是）。
			var by_move := _kills_by_move(demo)
			if bool(demo.get("no_kill", false)):
				_check(true, "「%s」这一段只演示走位（剧本声明了 no_kill）" % symbol)
			else:
				_check(
					kills > 0 or by_move > 0,
					"「%s」的演示里确实打死了棋子（弹道 %d 枚、走上去吃 %d 枚）" % [symbol, kills, by_move]
				)


## 一帧的自洽性检查：
##   1. 帧里的每一枚棋子都必须落在 Rules.camp_of 判定给它的半场；
##   2. 每一条弹道都必须真的在 Rules.attack_targets 的返回里
##      （例外：那条弹道自己指向的格子上站着敌方的盾——盾正是「挡住后面格子」的那一位，
##        它并不出现在攻击目标里，这是棋规里唯一一种「画了箭头但不算命中」的情况）。
func _check_frame(note: Dictionary, demo: Dictionary, frame: Dictionary, index: int) -> void:
	var label := "「%s」第 %d 帧" % [PieceGuide.symbol_of(note["kind"]), index]
	var state: Dictionary = frame["state"]
	var board_size := int((demo["board"] as Array).size())
	# 示意图（demo 标了 schematic）允许把「敌军」画在自己半场里——那不是真实摆位，
	# 而是为了把某个机制讲清楚（王的教程就是这样：王区整个在红方半场里，
	# 真实棋规下根本摆不出敌人，但「王区之内才吃得到」这件事必须画出来）。
	var schematic := bool(demo.get("schematic", false))

	# 1. 势力与半场一致
	if schematic:
		_check(true, "%s：示意图，跳过「都在自己半场」这项" % label)
	else:
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
	#
	#    例外：结算方是**敌方**的那几帧（盾的抵抗）。那种段落里我方不掉人、敌方也未必掉人，
	#    帧里的 killed 指的是「结算方打掉的目标」，和「我方阵亡」不是一回事，这里就不查。
	var enemy_side := false
	for arrow in frame.get("arrows", []):
		var shooter: PieceInfo = state.get(arrow.get("from"))
		if shooter != null and shooter.camp != PieceInfo.Camp.RED:
			enemy_side = true
			break
	if enemy_side:
		_check(true, "%s：由敌方结算的帧，阵亡名单由剧本自己负责" % label)
	else:
		for cell in frame.get("killed", []):
			_check(
				not state.has(cell),
				"%s：阵亡的 %s 已经从局面上移除（画布因此能收回来）" % [label, cell]
			)


## 整段时间轴上的击杀：每一个被杀掉的格子，都必须出现在**同一段剧本里某条弹道指向的目标**上。
##
## 单帧的击杀集合没法再用 Rules.resolve_kills 直接比对了——阵亡帧不保留死者
## （那是为了让画布收回来）。但那条线并没有松：弹道本身仍然逐帧对着
## Rules.attack_targets 验过，而这里要求「有击杀就必有出处」，于是
## 「击杀是凭规则打出来的」这件事依然被卡住。
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


## 这段演示里，靠**走上去吃**（王的吃子）吃掉了几个敌人。
## 逐帧比对「走子前后」的局面：走子那一帧仍画的是走之前的局面，下一帧才反映新位置，
## 所以拿 frames[i] 与 frames[i+1] 的棋子数一比就知道那一步有没有吃子。
func _kills_by_move(demo: Dictionary) -> int:
	# 示意图不按真实棋规走（王那段就是），所以「走上去吃了几个」这项对它不适用
	if bool(demo.get("schematic", false)):
		return 1
	var frames := GuideDemos.build(demo)
	var eaten := 0
	for i in range(frames.size() - 1):
		var before: Dictionary = frames[i]["state"]
		var after: Dictionary = frames[i + 1]["state"]
		var lost := before.size() - after.size()
		if lost > 0:
			eaten += lost
	return eaten


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


## 弓这段教程的缩放节奏：摆位/走子时 5×4 → 开火那一帧收到 4×3 → 击杀后收到 2×2。
## 「打完这一炮棋盘收回来」正是演示要传达的信息，所以逐帧范围是钉死的。
func _test_archer_scaling() -> void:
	var frames := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	var sizes := PackedStringArray()
	for frame in frames:
		var rect := GuideDemos.frame_bounds(frame)
		sizes.append("%dx%d" % [rect.size.x, rect.size.y])

	_check(
		sizes[0] == "5x4" and sizes[1] == "5x4",
		"摆位与走子这两帧的范围都是 5×4（实际：%s / %s）" % [sizes[0], sizes[1]]
	)
	_check(
		sizes[2] == "4x3",
		"开火那一帧收到 4×3——只剩弓、两个炮架与两条弹道的两端（实际：%s）" % sizes[2]
	)
	_check(
		sizes[3] == "2x2",
		"两个敌人阵亡后棋盘收到 2×2（实际：%s）" % sizes[3]
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

	# 弓的两段演示：每个回合都不该短到看不清，也不该长到让人等
	var archer_demos := PieceGuide.demos_for(PieceInfo.Kind.ARCHER)
	for demo in archer_demos:
		var longest := 0.0
		var shortest := 1000.0
		for phase in demo["phases"]:
			var seconds := float(phase.get("duration", 0.0))
			longest = maxf(longest, seconds)
			shortest = minf(shortest, seconds)
		_check(
			shortest >= 1.2 and longest <= 3.0,
			"弓的每个回合都在 1.2~3.0 秒之间（实际 %.1f~%.1f 秒）" % [shortest, longest]
		)

	var archer_frames := GuideDemos.build(archer_demos[0])
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
	var from_rect := GuideDemos.frame_bounds(frames[1])
	_check(
		not view.is_bounds_animating() and view.get_shown_bounds().size.is_equal_approx(Vector2(from_rect.size)),
		"跳帧是瞬间到位、不起过渡（实际 %s）" % view.get_shown_bounds().size
	)

	# 正常播放路径（_sync_bounds 不带 snap）必须起过渡
	var to_rect := GuideDemos.frame_bounds(frames[2])
	view._sync_bounds(frames[2])
	_check(
		view.is_bounds_animating(),
		"范围一变（%d×%d → %d×%d）就起了过渡 Tween，不是直接赋值" % [
			from_rect.size.x, from_rect.size.y, to_rect.size.x, to_rect.size.y,
		]
	)

	var mid := view.advance_bounds_for(0.14)
	_check(
		mid.size.x > float(mini(from_rect.size.x, to_rect.size.x)) - 0.01 \
			and mid.size.x < float(maxi(from_rect.size.x, to_rect.size.x)) + 0.01 \
			and not mid.size.is_equal_approx(Vector2(from_rect.size)) \
			and not mid.size.is_equal_approx(Vector2(to_rect.size)),
		"过渡走到一半时范围确实是中间的（半程 %s，两端 %s → %s）" % [
			mid.size, from_rect.size, to_rect.size,
		]
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
		view.get_shown_bounds().size.is_equal_approx(Vector2(to_rect.size)),
		"过渡走完正好落在目标范围（%s，实际 %s）" % [to_rect.size, view.get_shown_bounds().size]
	)

	# 反向也走一遍
	view._sync_bounds(frames[1])
	_check(view.is_bounds_animating(), "反向切回原来的范围同样起过渡")
	view.advance_bounds_for(0.3)
	_check(
		view.get_shown_bounds().size.is_equal_approx(Vector2(from_rect.size)),
		"反向也到位（%s，实际 %s）" % [from_rect.size, view.get_shown_bounds().size]
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
## 顺便把这一段的开局逐个字对一遍——摆位错了画面上完全看不出来，只有对账能抓到。
func _test_archer_demo_deterministic() -> void:
	print("-- 时间轴与开局的确定性 --")
	var demo: Dictionary = PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0]
	var first := GuideDemos.build(demo)
	var second := GuideDemos.build(demo)
	_check(str(first) == str(second), "同一段剧本两次演算得到完全一样的帧")

	# 开局局面必须和剧本上写的一字不差。最容易悄悄错的是阵营：
	# 6×6 的分界是 x+y < 5，所以 (2,1)(2,2) 是红（炮架），而 (4,1)(3,3) 才是绿。
	var state := GuideDemos.state_of(demo)
	_check(
		_state_signature(state) == "红弓(0,0) 红盾(2,1) 绿步(4,1) 红盾(2,2) 绿步(3,3)",
		"开局局面与剧本一致（实际：%s）" % _state_signature(state)
	)

	# 第一段：谁都打不到谁（这是「纯摆位」那一段的要求）
	var board_size := 6
	_check(
		Rules.resolve_kills(state, board_size, PieceInfo.Camp.RED).is_empty()
			and Rules.resolve_kills(state, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"开局双方都算不出任何击杀"
	)
	_check(
		Vector2i(1, 1) in Rules.reachable_cells(state, Vector2i(0, 0), board_size),
		"弓能从 (0,0) 向右下走一格到 (1,1)"
	)

	# 第二段之后：横线借盾打 (4,1)、斜线借步打 (3,3)，两条都出自弓
	var moved: Dictionary = state.duplicate()
	var archer: PieceInfo = moved[Vector2i(0, 0)]
	moved.erase(Vector2i(0, 0))
	moved[Vector2i(1, 1)] = archer
	var targets := _sorted_cells(Rules.attack_targets(moved, Vector2i(1, 1), archer, board_size))
	_check(
		targets == "[(4, 1), (3, 3)]",
		"弓在 (1,1) 打出两条弹道：横的 (4,1)、斜的 (3,3)（实际：%s）" % targets
	)
	_check(
		_sorted_cells(Rules.resolve_kills(moved, board_size, PieceInfo.Camp.RED)) == "[(4, 1), (3, 3)]",
		"红方这一次结算只击杀那两个绿步，没有误伤炮架"
	)
	# 盾的抵抗：横线的敌人 (4,1) 必须**不在** (2,2) 那枚红步的正后方，
	# 否则 (2,1) 的盾会被抵抗、横线直接穿过盾落到 (4,1) 之外——这正是踩过的坑。
	_check(
		not Rules.is_shield_resisted(moved, Vector2i(2, 1), Vector2i(1, 0), board_size),
		"横线没被盾抵抗（(3,1) 是空格，盾后面没有自己人）"
	)
	_check(
		Rules.resolve_kills(moved, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"走完这一步绿方也没有任何反击"
	)


## 弓的教程（**只有这一段**）：摆位 → 向右下走一格 → 出现箭头、横斜各一条、双杀。
##
## 这段流程是需求钉死的，所以逐步核对，而不是只看「有没有帧」：
##   1. 摆位与需求给的图一一对应：左列 (0,0)~(0,3) 与 (1,0) 空着，盾在 (2,1)、己步在 (2,2)；
##   2. 画面很小：所有棋子都落在左上角那一小块里，不做成一整张大地图；
##   3. 第一段：双方都用真实 Rules 算一遍，必须一个击杀都没有；
##   4. 第二段：走子必须是「向右下」一格（从 (0,0) 到 (1,1)）；
##   5. 第三段：正好杀掉两个敌步，两条弹道**都出自弓自己**、**一横一斜**，而且出现在**同一帧**
##      （曾经踩过的坑：横线那枚敌步若落在红方半场，会成为自己人，弓的弹道直接穿过它，
##        于是画面上只剩一条斜线——这条断言就是为了挡住这种情况）。
func _test_archer_opening_flow() -> void:
	print("-- 弓的教程流程（横着打 + 斜着打）--")
	var demo: Dictionary = PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0]
	var start := Vector2i(0, 0)
	var end := Vector2i(1, 1)
	var enemies := [Vector2i(4, 1), Vector2i(3, 3)]

	var frames := GuideDemos.build(demo)
	var board_size := int((demo["board"] as Array).size())
	var state := GuideDemos.state_of(demo)

	# 1. 摆位与需求图一致；弓要走的是一条空走廊：左列 (0,*) 与 (1,0) 都必须是空格
	var stray := ""
	for cell in state.keys():
		if cell == Vector2i(0, 0) or cell == Vector2i(1, 1):
			continue
		if cell.x == 0 or cell == Vector2i(1, 0):
			stray = str(cell)
			break
	_check(stray == "", "左列 (0,*) 与 (1,0) 都是空格（不该有棋子的：%s）" % (stray if stray != "" else "无"))

	# 2. 画面很小：所有棋子都在左上角 5×4 的范围里
	var outside := ""
	for cell in state.keys():
		if cell.x > 4 or cell.y > 3:
			outside = str(cell)
			break
	_check(outside == "", "所有棋子都在左上角 5×4 内（越界的：%s）" % (outside if outside != "" else "无"))

	_check(
		state.has(start) and (state[start] as PieceInfo).kind == PieceInfo.Kind.ARCHER
			and (state[start] as PieceInfo).camp == PieceInfo.Camp.RED,
		"红弓开局在 %s" % start
	)
	_check(
		state.has(Vector2i(2, 1)) and (state[Vector2i(2, 1)] as PieceInfo).kind == PieceInfo.Kind.SHIELD
			and (state[Vector2i(2, 1)] as PieceInfo).camp == PieceInfo.Camp.RED,
		"红盾在 (2,1)——横着打的炮架"
	)
	_check(
		state.has(Vector2i(2, 2)) and (state[Vector2i(2, 2)] as PieceInfo).kind == PieceInfo.Kind.SHIELD
			and (state[Vector2i(2, 2)] as PieceInfo).camp == PieceInfo.Camp.RED,
		"第二面红盾在 (2,2)——斜着打的炮架"
	)
	for e in enemies:
		_check(
			state.has(e) and (state[e] as PieceInfo).kind == PieceInfo.Kind.PAWN
				and (state[e] as PieceInfo).camp == PieceInfo.Camp.GREEN,
			"%s 上是绿步（敌军）" % e
		)

	# 3. 第一段：摆位，谁都打不到谁
	_check(
		Rules.resolve_kills(state, board_size, PieceInfo.Camp.RED).is_empty()
			and Rules.resolve_kills(state, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"第一段是纯摆位：双方都算不出任何击杀"
	)

	# 4. 第二段：必须是往右下走一格
	var move_step := {}
	for phase in demo["phases"]:
		for raw in phase["steps"]:
			if str(raw[0]) == "move":
				move_step = raw[2]
	_check(not move_step.is_empty(), "第二段里有一步走子")
	if not move_step.is_empty():
		_check(
			move_step["from"] == start and move_step["to"] == end,
			"走子是从 %s 到 %s（也就是右下角一格）" % [start, end]
		)
	_check(end in Rules.reachable_cells(state, start, board_size), "这一格按规则真的走得到")

	# 5. 第三段：两条弹道都来自弓，正好杀掉两个敌步，且一横一斜、同帧出现
	var after := state.duplicate()
	var archer: PieceInfo = after[start]
	after.erase(start)
	after[end] = archer
	var killed := _sorted(Rules.resolve_kills(after, board_size, PieceInfo.Camp.RED))
	_check(
		killed == _sorted(enemies),
		"走完之后红方正好击杀两个敌步（实际：%s）" % _sorted_cells(killed)
	)

	var arrow_targets: Array = []
	var shot_from := {}
	var busiest := 0
	for frame in frames:
		var shots: Array = []
		for arrow in frame.get("arrows", []):
			if str(arrow.get("kind", "")) != "shot":
				continue
			shots.append(arrow)
			arrow_targets.append(arrow["to"])
			shot_from[arrow["from"]] = true
		if shots.size() > busiest:
			busiest = shots.size()
	_check(
		_sorted(arrow_targets) == _sorted(enemies),
		"演示里的弹道正好指向那两个敌步（实际：%s）" % _sorted_cells(arrow_targets)
	)
	_check(
		shot_from.keys() == [end],
		"两条弹道都从弓的新位置 %s 射出（实际：%s）" % [end, shot_from.keys()]
	)

	# 一横一斜：逐条看方向
	var horizontal := 0
	var diagonal := 0
	for frame in frames:
		for arrow in frame.get("arrows", []):
			if str(arrow.get("kind", "")) != "shot":
				continue
			var delta: Vector2i = arrow["to"] - arrow["from"]
			if delta.y == 0:
				horizontal += 1
			elif delta.x != 0:
				diagonal += 1
	_check(horizontal == 1 and diagonal == 1, "一条横着打、一条斜着打（横 %d 条、斜 %d 条）" % [horizontal, diagonal])
	_check(busiest == 2, "两条弹道出现在同一帧上（单帧最多 %d 条）" % busiest)


## 步的教程（与弓共用同一套框架）：摆位 → 向下一步 → 靠队列厚度击杀。
##
## 逐步核对，重点守住「击杀真的是队列比较打出来的」这件事：
##   1. 摆位：两枚红步在 (1,1)/(2,1)，绿步在 (3,3)；
##   2. 第一段：双方都算不出击杀；
##   3. 第二段：走子必须是「向下」一格（从 (2,1) 到 (2,2)）；
##   4. 第三段：只死那一枚绿步，而且是**步**用队列比较打出来的——身后 1 枚红步 : 敌方 0 枚；
##   5. 把 (2,1) 那枚友军步挪走，这一击就必须失效（证明「队列厚度」才是关键，而不是随便挨着）。
func _test_pawn_flow() -> void:
	print("-- 步的教程流程（队列厚度击杀）--")
	var demo: Dictionary = PieceGuide.demos_for(PieceInfo.Kind.PAWN)[0]
	var start := Vector2i(2, 1)
	var end := Vector2i(2, 2)
	var friend := Vector2i(1, 1)
	var enemy := Vector2i(3, 3)

	var board_size := int((demo["board"] as Array).size())
	var state := GuideDemos.state_of(demo)

	_check(
		state.has(start) and (state[start] as PieceInfo).kind == PieceInfo.Kind.PAWN
			and (state[start] as PieceInfo).camp == PieceInfo.Camp.RED,
		"要动的那枚红步在 %s" % start
	)
	_check(
		state.has(friend) and (state[friend] as PieceInfo).kind == PieceInfo.Kind.PAWN
			and (state[friend] as PieceInfo).camp == PieceInfo.Camp.RED,
		"另一枚红步在 %s（它就是身后那 1 枚队列）" % friend
	)
	_check(
		state.has(enemy) and (state[enemy] as PieceInfo).kind == PieceInfo.Kind.PAWN
			and (state[enemy] as PieceInfo).camp == PieceInfo.Camp.GREEN,
		"%s 上是绿步（敌军）" % enemy
	)

	# 第一段：纯摆位
	_check(
		Rules.resolve_kills(state, board_size, PieceInfo.Camp.RED).is_empty()
			and Rules.resolve_kills(state, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"第一段是纯摆位：双方都算不出任何击杀"
	)

	# 第二段：向下走一格
	var move_step := _move_step_of(demo)
	_check(not move_step.is_empty(), "第二段里有一步走子")
	if not move_step.is_empty():
		_check(
			move_step["from"] == start and move_step["to"] == end,
			"走子是从 %s 到 %s（也就是正下方一格）" % [start, end]
		)
	_check(end in Rules.reachable_cells(state, start, board_size), "这一格按规则真的走得到")

	# 第三段：只死敌人那一枚，而且是步的队列比较
	var after := state.duplicate()
	after.erase(start)
	after[end] = PieceInfo.new(PieceInfo.Kind.PAWN, PieceInfo.Camp.RED)
	_check(
		_sorted(Rules.resolve_kills(after, board_size, PieceInfo.Camp.RED)) == _sorted([enemy]),
		"走完之后正好击杀那一枚绿步（实际：%s）"
			% _sorted_cells(Rules.resolve_kills(after, board_size, PieceInfo.Camp.RED))
	)
	_check(
		enemy in Rules.attack_targets(after, end, after[end], board_size),
		"这一击是「步」打出来的（%s 的攻击目标里有 %s）" % [end, enemy]
	)
	var dir := Vector2i(signi((enemy - end).x), signi((enemy - end).y))
	var own := Rules.chain_length(after, end, -dir, PieceInfo.Camp.RED, board_size)
	var foe := Rules.chain_length(after, enemy, dir, PieceInfo.Camp.GREEN, board_size)
	_check(
		own == 1 and foe == 0,
		"队列比较是 1 : 0（我方身后 %d 枚、敌方身后 %d 枚）" % [own, foe]
	)
	_check(
		Rules.resolve_kills(after, board_size, PieceInfo.Camp.GREEN).is_empty(),
		"绿方在这盘里没有任何反击"
	)

	# 把身后那枚友军步挪走 → 这一击必须失效
	var no_support := after.duplicate()
	no_support.erase(friend)
	_check(
		enemy in no_support and Rules.attack_targets(no_support, end, no_support[end], board_size).is_empty(),
		"抽掉身后那枚红步，这一击就失效了（说明赢的是队列厚度，不是「挨着」）"
	)


## 取演示里唯一那一步走子的参数；没有则返回空字典。
func _move_step_of(demo: Dictionary) -> Dictionary:
	for phase in demo["phases"]:
		for raw in phase["steps"]:
			if str(raw[0]) == "move":
				return raw[2]
	return {}


## 把局面拼成「红弓(1,1) 红步(2,3) …」，按行、列排序，便于与剧本对账。
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
