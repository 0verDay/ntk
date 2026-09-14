extends Node

## 主菜单与「棋子指南」的界面测试。
##
## 和 test_game_ui.gd 一样必须跑在真实窗口里：headless 下引擎不派发模拟鼠标事件，
## 「按钮有没有被上层控件挡住」根本测不出来。
##
## 运行：godot --path <项目目录> --resolution 1280x720 res://tests/test_menu_ui.tscn
## 退出码 0 表示全部通过。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const GUIDE_SCENE := "res://scenes/guide.tscn"

const GUIDE_BUTTON := "CenterContainer/VBoxContainer/GuideButton"

var _passed := 0
var _failed := 0
## _run() 全程跑完才会置为 true。中途因为脚本错误中断时它仍是 false，
## 这样就不会出现「测试半路挂了、却打印『失败 0 项』并返回 0」这种假通过。
var _completed := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("本测试需要真实窗口：headless 下引擎不派发模拟鼠标事件，点击类断言无法判定。")
		printerr("请去掉 --headless 运行（tests/run-tests.ps1 已经这么做）。")
		get_tree().quit(1)
		return

	# 本测试节点就是主场景；置空 current_scene，测试节点才不会在被切场景时被释放
	get_tree().current_scene = null
	await _run()
	if not _completed:
		printerr("测试没有跑完就中断了（多半是上面的 SCRIPT ERROR），按失败处理。")
		get_tree().quit(1)
		return
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	print("=== 主菜单 / 棋子指南测试 ===")

	var menu: Node = load(MAIN_MENU_SCENE).instantiate()
	add_child(menu)
	await _settle()

	var guide_button: Button = menu.get_node(GUIDE_BUTTON)
	_check(guide_button.visible and not guide_button.disabled, "主菜单有可点的「棋子指南」按钮")

	var guide_button_name := String(guide_button.name)
	var hit := await _click(guide_button)
	_check(hit == guide_button_name, "点「棋子指南」没被挡住（实际命中：%s）" % hit)
	await _settle()

	var guide := get_tree().current_scene
	_check(
		guide != null and guide.scene_file_path == GUIDE_SCENE,
		"点「棋子指南」进入指南界面（实际：%s）" % (guide.scene_file_path if guide != null else "无")
	)
	if guide == null or guide.scene_file_path != GUIDE_SCENE:
		return

	# 每种棋子都得有说明：以 PieceInfo.SYMBOLS 为权威清单，漏一种就红
	var text := _collect_text(guide)
	var notes: Array = PieceGuide.PIECE_NOTES
	_check(
		notes.size() == PieceInfo.SYMBOLS.size(),
		"指南覆盖了全部 %d 种棋子（实际写了 %d 种）" % [PieceInfo.SYMBOLS.size(), notes.size()]
	)
	for kind in PieceInfo.SYMBOLS.keys():
		var symbol := String(PieceInfo.SYMBOLS[kind])
		_check(text.contains(symbol), "指南里写到了「%s」" % symbol)

	# 每张卡片还应该有实际说明文字，不能只有个棋名
	for note in notes:
		var name := String(PieceInfo.SYMBOLS.get(note["kind"], "?"))
		_check(
			String(note.get("tagline", "")).length() > 0 and (note["points"] as Array).size() > 0,
			"「%s」的说明不为空（%d 条）" % [name, (note["points"] as Array).size()]
		)

	# 指南开头写的兵力「王×1、弓×2、骑×2、盾×2、步×2」必须和真实初始布局对得上，
	# 免得改了 INITIAL_LAYOUT 之后指南悄悄说谎
	var claim := _troop_claim()
	_check(text.contains(claim), "指南里写的双方兵力「%s」与真实初始布局一致" % claim)
	_check(_counts_of(PieceInfo.Camp.RED) == _counts_of(PieceInfo.Camp.GREEN), "红绿双方兵力完全对称")

	# 内容比可视区高，说明确实能滚动翻看
	var scroll: ScrollContainer = guide.get_node("Margin/Scroll")
	await _settle()
	var bar := scroll.get_v_scroll_bar()
	_check(
		bar.max_value > bar.page,
		"指南内容超过一屏、可以滚动（内容 %.0f / 可视 %.0f）" % [bar.max_value, bar.page]
	)

	# 返回主菜单：同样要点得到，不能被那个满屏 MarginContainer 挡住。
	# 注意这一击会把指南场景整个释放掉，所以只能拿事先存好的名字来比对。
	var back: Button = guide.get_node("BackButton")
	var back_name := String(back.name)
	var hit_back := await _click(back)
	_check(hit_back == back_name, "指南的「返回主菜单」没被挡住（实际命中：%s）" % hit_back)
	await _settle()
	_check(
		get_tree().current_scene != null and get_tree().current_scene.scene_file_path == MAIN_MENU_SCENE,
		"指南可以返回主菜单"
	)

	menu.queue_free()
	await get_tree().process_frame
	_completed = true


# --- 工具 ---

## 在控件中心做一次真实鼠标点击，返回**实际命中控件的节点名**。
##
## push_input 会走一遍 GUI 命中测试，所以「被上层控件挡住」能被测出来；
## emit_signal("pressed") 是绕过命中测试的，测不出遮挡。
##
## 返回名字而不是节点本身：点击常常会触发 change_scene_to_file，
## 把命中的节点连同场景一起释放，await 回来再访问它就会报 "previously freed"。
func _click(control: Control) -> String:
	var at := control.get_global_rect().get_center()

	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)
	var hit: Control = get_viewport().gui_get_hovered_control()
	var hit_name := "无" if hit == null else String(hit.name)

	for is_press in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = is_press
		button.position = at
		button.global_position = at
		get_viewport().push_input(button)
	await get_tree().process_frame
	return hit_name


## 递归收集一棵界面子树里的全部文字，用来检查「写了什么」。
func _collect_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += (node as Label).text + "\n"
	elif node is RichTextLabel:
		text += (node as RichTextLabel).get_parsed_text() + "\n"
	for child in node.get_children():
		text += _collect_text(child)
	return text


## 统计某一方在初始布局里的各兵种数量。
func _counts_of(camp: PieceInfo.Camp) -> Dictionary:
	var state := Session.initial_state(7)
	var counts := {}
	for cell in state.keys():
		var info: PieceInfo = state[cell]
		if info.camp == camp:
			counts[info.kind] = int(counts.get(info.kind, 0)) + 1
	return counts


## 把真实初始布局的兵力拼成「王×1、弓×2、…」，用来和指南里写的对账。
func _troop_claim() -> String:
	var counts := _counts_of(PieceInfo.Camp.RED)
	var order := [
		PieceInfo.Kind.KING, PieceInfo.Kind.ARCHER, PieceInfo.Kind.KNIGHT,
		PieceInfo.Kind.SHIELD, PieceInfo.Kind.PAWN,
	]
	var parts := PackedStringArray()
	for kind in order:
		parts.append("%s×%d" % [PieceInfo.SYMBOLS[kind], int(counts.get(kind, 0))])
	return "、".join(parts)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _check(condition: bool, title: String) -> void:
	if condition:
		_passed += 1
		print("  [通过] %s" % title)
	else:
		_failed += 1
		printerr("  [失败] %s" % title)
