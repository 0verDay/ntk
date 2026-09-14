extends Node

## 指南里那些「动画」的测试：不碰鼠标、不跑棋规，所以可以 headless 跑。
##
## 从这一版起指南演示是**纯动画**：每一帧自己写清了画什么（棋子 / 箭头 / 高亮 / 文字 / 停留多久）。
## 游戏端只按顺序画，不再拿 rules.gd 演算——所以这里能守的是「帧数据本身对不对、画不画得出来」：
## 文字有没有写、停留时间是不是正的、棋子与箭头是不是都在棋盘里、相邻两帧是不是重复、
## 画布范围与逐帧缩放对不对、控件能不能播。
##
## **不再守**的是「画面和棋规一致」——那件事没人替你做了，改棋规之后请自己回来核对演示。
##
## 剧本来自 tools/demos/*.py 导出的 data/guide_demos.json（见 tools/README.md）：
## 所以「JSON 忘了导出 / 漏了兵种 / 文案为空」这类毛病也会在这里现形。
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
	print("=== 指南动画测试 ===")
	_test_every_note_has_demos()
	_test_frames_are_well_formed()
	_test_no_duplicate_frames()
	_test_holds()
	await _test_demo_bounds()
	await _test_bounds_transition_is_animated()
	await _test_demo_control_plays()
	_completed = true


# --- 用例 ---

## 每条棋子说明都得配一段动画（现在五种都有，骑有两段）。
##
## 数据不在 GDScript 里，而是 tools/demos/*.py 经 export_guide_demos.py 导出成
## data/guide_demos.json；所以这里同时也在守「JSON 是不是漏了导出、漏了兵种」。
func _test_every_note_has_demos() -> void:
	print("-- 棋子说明与动画的对应关系 --")
	for note in PieceGuide.PIECE_NOTES:
		var kind: int = note["kind"]
		var symbol := PieceGuide.symbol_of(kind)
		var demos := PieceGuide.demos_for(kind)
		_check(not demos.is_empty(), "「%s」有动画（现在 %d 段）" % [symbol, demos.size()])
		for demo in demos:
			_check(
				not str(demo.get("caption", "")).is_empty()
					and int(demo.get("size", 0)) > 0
					and not (demo.get("frames", []) as Array).is_empty(),
				"「%s」的剧本有标题、棋盘边长和帧" % symbol
			)

	_check(not PieceGuide.demos_for(PieceInfo.Kind.ARCHER).is_empty(), "demos_for() 能取到弓的动画")
	_check(not PieceGuide.demos_for(PieceInfo.Kind.PAWN).is_empty(), "demos_for() 也能取到步的动画")
	_check(PieceGuide.demos_for(PieceInfo.Kind.KNIGHT).size() == 2, "骑有两段动画（连跳 + 夹击）")
	_check(PieceGuide.note_for(-1).is_empty(), "问一个不存在的兵种时返回空字典（不是报错）")


## 每一帧都得是自己能成立的一张画：有文字、停留时间是正的、棋子/箭头/高亮都在棋盘里。
func _test_frames_are_well_formed() -> void:
	print("-- 每一帧的数据都成立 --")
	for note in PieceGuide.PIECE_NOTES:
		var symbol := PieceGuide.symbol_of(note["kind"])
		for demo in PieceGuide.demos_for(note["kind"]):
			var size := int(demo["size"])
			var frames := GuideDemos.build(demo)
			_check(
				frames.size() == (demo.get("frames", []) as Array).size(),
				"「%s」的 %d 帧都解出来了" % [symbol, frames.size()]
			)
			var bad_text := 0
			var bad_cell := 0
			var bad_arrow := 0
			for frame in frames:
				if str(frame["text"]).strip_edges().is_empty():
					bad_text += 1
				for cell in (frame["state"] as Dictionary).keys():
					if not Rules.is_inside(cell, size):
						bad_cell += 1
				for cell in (frame["highlight"] as Dictionary).keys():
					if not Rules.is_inside(cell, size):
						bad_cell += 1
				for arrow in frame["arrows"]:
					if not Rules.is_inside(arrow["from"], size) or not Rules.is_inside(arrow["to"], size):
						bad_arrow += 1
					if not (str(arrow["kind"]) in GuideDemos.ARROW_STYLES):
						bad_arrow += 1
			_check(bad_text == 0, "「%s」每帧都有文字（空的：%d 帧）" % [symbol, bad_text])
			_check(bad_cell == 0, "「%s」棋子和高亮都在 %d×%d 棋盘里（越界：%d）" % [symbol, size, size, bad_cell])
			_check(bad_arrow == 0, "「%s」箭头的两端都在棋盘里、样式也认得出（问题：%d）" % [symbol, bad_arrow])


## 相邻两帧不能一模一样：那等于同一张画白停了两倍时间，多半是复制出来忘了改。
func _test_no_duplicate_frames() -> void:
	print("-- 没有画面完全相同的相邻帧 --")
	for note in PieceGuide.PIECE_NOTES:
		var symbol := PieceGuide.symbol_of(note["kind"])
		for demo in PieceGuide.demos_for(note["kind"]):
			var frames := GuideDemos.build(demo)
			var duplicates := 0
			for index in range(frames.size() - 1):
				if _frame_signature(frames[index]) == _frame_signature(frames[index + 1]):
					duplicates += 1
			_check(duplicates == 0, "「%s」相邻两帧没有一模一样的（重复：%d 处）" % [symbol, duplicates])


## 帧的「内容签名」：刻意不含 hold——停留时间不同、画面一样，仍然算重复。
func _frame_signature(frame: Dictionary) -> String:
	var copy := frame.duplicate()
	copy.erase("hold")
	return str(copy)


## 停留时间：每帧都得停一会儿（0 会让动画卡住），但也别短到看不清。
func _test_holds() -> void:
	print("-- 每帧的停留时间 --")
	for note in PieceGuide.PIECE_NOTES:
		var symbol := PieceGuide.symbol_of(note["kind"])
		for demo in PieceGuide.demos_for(note["kind"]):
			var frames := GuideDemos.build(demo)
			var too_short := 0
			var total := 0.0
			for frame in frames:
				total += float(frame["hold"])
				if float(frame["hold"]) < 0.4:
					too_short += 1
			_check(too_short == 0, "「%s」每帧都至少停 0.4 秒（太短的：%d 帧）" % [symbol, too_short])
			_check(total > 0.0, "「%s」整段时长 %.1f 秒" % [symbol, total])

	var archer := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	_check(
		absf(_total_of(archer) - 6.0) < 0.01,
		"弓那段一共演 6.0 秒（实际 %.2f）" % _total_of(archer)
	)


func _total_of(frames: Array) -> float:
	var total := 0.0
	for frame in frames:
		total += float(frame["hold"])
	return total


## 画布范围：整段取并集（不逐帧变，否则卡片里的文字会抖），棋盘在里面逐帧缩放。
func _test_demo_bounds() -> void:
	print("-- 画布与逐帧缩放 --")
	for note in PieceGuide.PIECE_NOTES:
		var symbol := PieceGuide.symbol_of(note["kind"])
		for demo in PieceGuide.demos_for(note["kind"]):
			var size := int(demo["size"])
			var frames := GuideDemos.build(demo)
			if frames.is_empty():
				continue
			var bounds := GuideDemos.bounds_of(frames)

			# 1. 画布要把每一帧必须看见的格子都包住
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
				"「%s」每一帧必须看见的格子都在画布内（越界的那格：%s）" % [symbol, first_outside if first_outside != "" else "无"]
			)

			# 2. 画布不能超出真实棋盘
			_check(
				bounds.position.x >= 0 and bounds.position.y >= 0
					and bounds.end.x <= size and bounds.end.y <= size,
				"「%s」画布 %s 没有超出 %d×%d 棋盘" % [symbol, bounds, size, size]
			)

			# 3. 逐帧的紧凑范围也要覆盖该帧的元素
			var frame_outside := ""
			for frame in frames:
				var rect := GuideDemos.frame_bounds(frame)
				for cell in _visible_cells(frame):
					if not rect.has_point(cell):
						frame_outside = str(cell)
						break
				if frame_outside != "":
					break
			_check(
				frame_outside == "",
				"「%s」每帧的紧凑范围都覆盖了该帧的元素（漏掉的：%s）" % [symbol, frame_outside if frame_outside != "" else "无"]
			)

	# 弓那段的缩放节奏（现在是写死的帧数据，所以范围也是钉死的）：
	# 摆位/走子时弓还在 (0,0)，范围 5×4；走到 (1,1)、只剩一条斜线时收到 4×3；
	# 两个敌人从画面上消失后收到 2×2——「打完这一炮棋盘收回来」正是这段要传达的。
	var archer_frames := GuideDemos.build(PieceGuide.demos_for(PieceInfo.Kind.ARCHER)[0])
	var sizes := PackedStringArray()
	for frame in archer_frames:
		var rect := GuideDemos.frame_bounds(frame)
		sizes.append("%dx%d" % [rect.size.x, rect.size.y])
	_check(" → ".join(sizes) == "5x4 → 5x4 → 4x3 → 2x2",
		"弓那段逐帧范围 5×4 → 5×4 → 4×3 → 2×2（实际 %s）" % " → ".join(sizes))
	var canvas := GuideDemos.bounds_of(archer_frames)
	_check(canvas.size.x == 6 and canvas.size.y == 5, "弓那段的画布是 6×5（实际 %d×%d）" % [canvas.size.x, canvas.size.y])
	print("  逐帧范围：", " → ".join(sizes), "；画布 ", canvas.size)


## 一帧里「必须看见」的格子：棋子、高亮、箭头两端。
func _visible_cells(frame: Dictionary) -> Array:
	var cells: Array = []
	for cell in (frame["state"] as Dictionary).keys():
		cells.append(cell)
	for cell in (frame["highlight"] as Dictionary).keys():
		cells.append(cell)
	for arrow in frame["arrows"]:
		cells.append(arrow["from"])
		cells.append(arrow["to"])
	return cells


## 缩放必须是**过渡**出来的，不能换帧时跳一下。
##
## 这条是防回归用的，针对一个真实踩过的坑：GDScript 给普通成员赋值**不会**触发重绘，
## 所以「Tween 在动、画面却停在过渡的第一帧」——看起来就是一次突变。
##
## 验证方式刻意不靠 `await process_frame` 采样：一次 await 往往推进好几帧，
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
	var to_rect := GuideDemos.frame_bounds(frames[3])
	view._sync_bounds(frames[3])
	_check(
		view.is_bounds_animating(),
		"范围一变（%d×%d → %d×%d）就起了过渡 Tween，不是直接赋值" % [
			from_rect.size.x, from_rect.size.y, to_rect.size.x, to_rect.size.y,
		]
	)

	var mid := view.advance_bounds_for(0.14)
	_check(
		mid.size.x > float(mini(from_rect.size.x, to_rect.size.x)) - 0.01
			and mid.size.x < float(maxi(from_rect.size.x, to_rect.size.x)) + 0.01
			and not mid.size.is_equal_approx(Vector2(from_rect.size))
			and not mid.size.is_equal_approx(Vector2(to_rect.size)),
		"过渡走到一半时范围确实是中间的（半程 %s，两端 %s → %s）" % [mid.size, from_rect.size, to_rect.size]
	)

	var before := view.get_redraw_requests()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(view.get_redraw_requests() > before,
		"过渡途中还在持续请求重绘（%d → %d，画面不会冻在中间）" % [before, view.get_redraw_requests()])

	view.advance_bounds_for(0.3)
	_check(
		view.get_shown_bounds().size.is_equal_approx(Vector2(to_rect.size)),
		"过渡走完正好落在目标范围（%s，实际 %s）" % [to_rect.size, view.get_shown_bounds().size]
	)
	view.queue_free()
	await get_tree().process_frame


## 演示控件本身：能载入帧、能自动播、说明文字跟着帧走、传空数组不炸。
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

	var shot_index := _first_arrow_frame(view)
	_check(shot_index >= 0, "时间轴里存在带箭头的帧")
	if shot_index >= 0:
		view.goto_frame(shot_index)
		var arrows: Array = view.get_current_frame()["arrows"]
		_check(arrows.size() > 0, "该帧画了 %d 条箭头" % arrows.size())
		_check(not view.get_status_text().is_empty(), "该帧有说明文字：%s" % view.get_status_text())

	view.set_frames([])
	_check(view.get_frame_count() == 0, "传空帧列表不报错，只是什么都不画")
	view.queue_free()
	await get_tree().process_frame


func _first_arrow_frame(view: GuideDemo) -> int:
	for index in range(view.get_frame_count()):
		view.goto_frame(index)
		if not (view.get_current_frame()["arrows"] as Array).is_empty():
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
