extends Node

## 游玩界面的行为测试（不需要服务端）：
##   - 「返回主菜单」在单机与联机模式下都可见，且按下后真的切回主菜单；
##   - 聊天面板的展开/收起、未读提醒、单机发言、联机回显、BBCode 转义、旧服务端降级。
##
## 运行：godot --headless --path <项目目录> res://tests/test_game_ui.tscn
## 退出码 0 表示全部通过。

const GAME_SCENE := "res://scenes/game.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

const BACK_BUTTON := "BackButton"
const CHAT_TOGGLE := "ChatToggleButton"
const BOARD := "ContentMargin/BoardArea/Board"
const CHAT_PANEL := "ChatPanel"
const CHAT_LOG := "ChatPanel/ChatMargin/ChatColumn/ChatLog"
const CHAT_INPUT := "ChatPanel/ChatMargin/ChatColumn/ChatInputRow/ChatInput"
const CHAT_SEND := "ChatPanel/ChatMargin/ChatColumn/ChatInputRow/ChatSendButton"

var _passed := 0
var _failed := 0
## _run() 全程跑完才会置为 true。中途因为脚本错误中断时它仍是 false，
## 这样就不会出现「测试半路挂了、却打印『失败 0 项』并返回 0」这种假通过。
var _completed := false


func _ready() -> void:
	# 点击类断言必须跑在真实窗口里：headless 模式下引擎根本不派发模拟鼠标事件
	# （mouse_in_viewport 一直是 false），命中测试永远返回「无」，
	# 这会让「按钮被挡住」和「引擎不支持」两种完全不同的原因表现成一模一样。
	# 所以这里宁可响亮地失败，也不要在 headless 下悄悄跳过点击断言。
	if DisplayServer.get_name() == "headless":
		printerr("本测试需要真实窗口：headless 下引擎不派发模拟鼠标事件，点击类断言无法判定。")
		printerr("请去掉 --headless 运行（tests/run-tests.ps1 已经这么做）。")
		get_tree().quit(1)
		return

	# 本测试节点就是主场景。change_scene_to_file 会释放 current_scene，
	# 先把 current_scene 置空，测试节点才能活到「检查是否切回了主菜单」那一步。
	get_tree().current_scene = null
	await _run()
	if not _completed:
		printerr("测试没有跑完就中断了（多半是上面的 SCRIPT ERROR），按失败处理。")
		get_tree().quit(1)
		return
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	print("=== 游玩界面测试 ===")
	await _test_offline()
	await _test_long_press()
	await _test_online()
	_completed = true


# --- 单机模式 ---

func _test_offline() -> void:
	print("-- 单机模式 --")
	Net.disconnect_from_server()
	var game := await _open_game()

	_check(game.get_node(BACK_BUTTON).visible, "「返回主菜单」在单机模式下可见")
	_check(
		game.get_node(CHAT_INPUT).max_length == GameServer.CHAT_MAX_LENGTH,
		"聊天输入框长度上限取自 GameServer.CHAT_MAX_LENGTH"
	)
	_check(not game.get_node(CHAT_PANEL).visible, "单机模式默认收起聊天面板")
	_check_no_overlap(game, "单机收起聊天面板时")

	# 展开聊天面板：棋盘必须纹丝不动，面板只占棋盘右边的空当。
	# 这里用真实鼠标点击（走 GUI 命中测试），而不是 emit_signal("pressed")——
	# 后者绕过命中测试，测不出「被上层控件挡住」。
	var board_before := _board_square_rect(game)
	var toggle: Button = game.get_node(CHAT_TOGGLE)
	var hit_toggle: Control = await _click(toggle)
	_check(hit_toggle == toggle, "鼠标点在「聊天」中央没被挡住（实际命中：%s）" % _name_of(hit_toggle))
	_check(game.get_node(CHAT_PANEL).visible, "鼠标点「聊天」能展开面板")
	_check(game.get_node(CHAT_TOGGLE).text == "聊天", "展开后按钮回到「聊天」")
	await _settle()
	_check(_board_square_rect(game) == board_before,
		"展开聊天面板后棋盘没有移动（%s → %s）" % [board_before, _board_square_rect(game)])
	_check_no_overlap(game, "展开聊天面板后")

	# 单机发言：本机直接上屏（没有服务端可发）
	var input: LineEdit = game.get_node(CHAT_INPUT)
	input.text = "  单机测试 [b]不是标签[/b]  "
	await _click(game.get_node(CHAT_SEND))
	var log: RichTextLabel = game.get_node(CHAT_LOG)
	_check(log.get_parsed_text().contains("单机测试 [b]不是标签[/b]"), "单机发言直接写进聊天记录")
	_check(input.text.is_empty(), "发言后输入框被清空")
	_check(log.get_parsed_text().contains("红方"), "单机记录按当前回合方署名")

	# 纯空白不发
	var before := log.get_parsed_text()
	input.text = "    "
	await _click(game.get_node(CHAT_SEND))
	_check(log.get_parsed_text() == before, "纯空白不会产生聊天记录")

	# 收起后收到新消息 -> 按钮上出现未读条数
	await _click(game.get_node(CHAT_TOGGLE))
	game._append_chat(PieceInfo.Camp.GREEN, "新消息")
	await get_tree().process_frame
	_check(game.get_node(CHAT_TOGGLE).text == "聊天 (1)", "面板收起时未读条数显示在按钮上")

	# 返回主菜单
	var back: Button = game.get_node(BACK_BUTTON)
	var hit_back: Control = await _click(back)
	_check(hit_back == back, "鼠标点在「返回主菜单」中央没被挡住（实际命中：%s）" % _name_of(hit_back))
	await _settle()
	_check(
		get_tree().current_scene != null and get_tree().current_scene.scene_file_path == MAIN_MENU_SCENE,
		"单机模式按「返回主菜单」确实切回主菜单"
	)
	await _clear_scene()
	game.queue_free()
	await get_tree().process_frame


# --- 长按棋子看卡片 ---

## 长按某个棋子 → 弹出指南卡片；松手消失；短按仍然只是选子。
func _test_long_press() -> void:
	print("-- 长按棋子看卡片 --")
	Net.disconnect_from_server()
	var game := await _open_game()
	var board: Board = game.get_node(BOARD)
	var card: PanelContainer = game.get_node("GuideCard")
	_check(not card.visible, "没长按时卡片不显示")

	# 开局红王在 (0,0)、红弓在 (2,0)
	var king_at := _cell_screen_pos(board, 0, 0)
	await _press(king_at)
	_check(not card.visible, "刚按下时还不弹卡片（还没到长按时长）")
	# 越过长按阈值（棋盘默认 0.4 秒）
	await get_tree().create_timer(board.long_press_duration + 0.15).timeout
	_check(card.visible, "按住 %.2f 秒后弹出卡片" % board.long_press_duration)
	_check(_collect_text(card).contains(PieceGuide.note_for(PieceInfo.Kind.KING)["tagline"]),
		"卡片里是「王」的说明")

	# 位置与尺寸：左侧空白区、上下铺满屏幕
	var board_left := board.global_position.x + (board.size.x - minf(board.size.x, board.size.y)) * 0.5 + board.frame_width
	var view_size := get_viewport().get_visible_rect().size
	_check(is_equal_approx(card.position.x, 32.0), "卡片左边距屏幕 32px（实际 %.0f）" % card.position.x)
	_check(is_equal_approx(card.position.y, 32.0), "卡片上边距屏幕 32px（实际 %.0f）" % card.position.y)
	_check(is_equal_approx(card.position.x + card.size.x, board_left - 32.0),
		"卡片右边缘与棋盘左边缘留 32px（实际 %.0f，棋盘在 %.0f）" % [card.position.x + card.size.x, board_left])
	_check(is_equal_approx(card.size.y, view_size.y - 64.0),
		"卡片高度 = 屏幕高 − 64（实际 %.0f / 屏幕 %.0f）" % [card.size.y, view_size.y])
	_check(card.mouse_filter == Control.MOUSE_FILTER_IGNORE, "卡片不吃鼠标事件（不会挡住棋盘或按钮）")

	await _release(king_at)
	_check(not card.visible, "松手后卡片消失")

	# 短按：只选子，不弹卡片
	var archer_at := _cell_screen_pos(board, 2, 0)
	await _press(archer_at)
	await _release(archer_at)
	_check(not card.visible, "短按不会弹出卡片")
	_check(board.get_selected_cell() == Vector2i(2, 0), "短按仍然是正常的选中棋子")

	# 换一枚棋子，卡片内容要跟着换
	await _press(archer_at)
	await get_tree().create_timer(board.long_press_duration + 0.15).timeout
	_check(card.visible, "长按另一枚棋子同样会弹出卡片")
	_check(_collect_text(card).contains(PieceGuide.note_for(PieceInfo.Kind.ARCHER)["tagline"]),
		"卡片内容换成了「弓」的说明")
	await _release(archer_at)

	# 长按空格子：没有棋子就没有卡片
	var empty_at := _cell_screen_pos(board, 3, 3)
	await _press(empty_at)
	await get_tree().create_timer(board.long_press_duration + 0.15).timeout
	_check(not card.visible, "长按空格子不会弹卡片")
	await _release(empty_at)

	# 宽卡片（聊天收起）应当写完每一条，不留指路句
	var king_points: Array = PieceGuide.note_for(PieceInfo.Kind.KING)["points"]
	await _press(king_at)
	await get_tree().create_timer(board.long_press_duration + 0.15).timeout
	var wide_text := _collect_text(card)
	_check(game.get_guide_card_point_font_size() == 13,
		"宽卡片用原字号（实际 %d）" % game.get_guide_card_point_font_size())
	_check(wide_text.contains(String(king_points[king_points.size() - 1])), "宽卡片把说明写完了")
	_check(not wide_text.contains("完整说明见主菜单"), "宽卡片不需要指路句")
	_check(_first_partial_point_label(card, king_points).is_empty(),
		"宽卡片没有半截说明（%s）" % _first_partial_point_label(card, king_points))
	_check(_point_labels(card).size() == king_points.size(),
		"宽卡片把 %d 条说明都写全了（实际 %d 条）" % [king_points.size(), _point_labels(card).size()])
	await _release(king_at)

	# 展开聊天面板不会挤压左侧空白区（棋盘不动），所以卡片宽度也不该变
	var wide_card_width := card.size.x
	game._set_chat_panel_visible(true)
	await _settle()
	await _press(king_at)
	await get_tree().create_timer(board.long_press_duration + 0.15).timeout
	_check(card.visible, "展开聊天面板后卡片照常弹出")
	_check(is_equal_approx(card.size.x, wide_card_width),
		"展开聊天面板后卡片宽度不变（%.0f → %.0f）" % [wide_card_width, card.size.x])
	await _release(king_at)
	game._set_chat_panel_visible(false)
	await _settle()

	# 直接造一个窄卡片验证降级逻辑：真实窗口缩窄在测试里不好稳定复现，
	# 而 _fill_guide_card 本来就只认 _guide_card.size。
	# 要求是：字号自动调小，且要么写完最后一条、要么指向完整指南——绝不拦腰截断。
	card.size = Vector2(116, 656)
	game._fill_guide_card(PieceGuide.note_for(PieceInfo.Kind.KING))
	_check(game.get_guide_card_point_font_size() < 13,
		"窄卡片字号自动调小（实际 %d）" % game.get_guide_card_point_font_size())
	var narrow_text := _collect_text(card)
	_check(narrow_text.contains(String(king_points[king_points.size() - 1])) or narrow_text.contains("完整说明见主菜单"),
		"窄卡片要么写完最后一条，要么指向完整指南")
	_check(_first_partial_point_label(card, king_points).is_empty(),
		"窄卡片也没有半截说明（%s）" % _first_partial_point_label(card, king_points))

	game.queue_free()
	await get_tree().process_frame


## 卡片里以「・」开头的标签，都必须正好等于某一条完整说明。
## 返回第一条「不是完整说明」的标签，没有则返回空串。
##
## 比「拿整段文字做前缀匹配」可靠：不同棋子的说明常常有相同开头
## （比如王和弓都以「移动：八方向走一格」开头），前缀匹配会误报。
func _first_partial_point_label(card: Node, points: Array) -> String:
	var whole := {}
	for point in points:
		whole["・%s" % point] = true
	for text in _point_labels(card):
		if not whole.has(text):
			return text
	return ""


## 卡片里所有以「・」开头的标签文字。
func _point_labels(card: Node) -> Array[String]:
	var all: Array[String] = []
	_collect_labels(card, all)
	var bullets: Array[String] = []
	for text in all:
		if text.begins_with("・"):
			bullets.append(text)
	return bullets


func _collect_labels(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	for child in node.get_children():
		_collect_labels(child, out)


# --- 联机模式 ---

func _test_online() -> void:
	print("-- 联机模式 --")
	await _clear_scene()
	# 伪造「服务端已经开局」的进场条件
	Net.in_game = true
	Net.my_camp = PieceInfo.Camp.GREEN
	Net.last_snapshot = _fake_snapshot()
	var game := await _open_game()

	_check(game.get_node(BACK_BUTTON).visible, "「返回主菜单」在联机模式下可见")
	_check(game.get_node(CHAT_PANEL).visible, "联机模式默认展开聊天面板")
	_check(game.get_node(CHAT_INPUT).editable, "联机模式聊天输入可用")
	_check_no_overlap(game, "联机展开聊天面板时")

	var log: RichTextLabel = game.get_node(CHAT_LOG)
	var turn_label: Label = game.get_node("TurnLabel")
	var turn_before := turn_label.text

	# 对手发言：走 Net 收包的完整路径（_apply_server_message + server_message 信号）
	_deliver("chat", {"camp": PieceInfo.Camp.RED, "text": "轮到你了"})
	await get_tree().process_frame
	_check(log.get_parsed_text().contains("轮到你了"), "对手的聊天经服务端回显后上屏")
	_check(log.get_parsed_text().contains("对手"), "对手的消息署名为「对手」")

	# 自己的发言也要等回显，且署名「我」
	_deliver("chat", {"camp": PieceInfo.Camp.GREEN, "text": "我看见了"})
	await get_tree().process_frame
	_check(log.get_parsed_text().contains("我看见了"), "自己的聊天在服务端回显后上屏")
	_check(Net.chat_history.size() == 2, "Net 会缓存聊天记录，供场景切换途中补显示")

	# 场景切换途中到达的消息靠 Net.chat_history 补显示
	game.queue_free()
	await get_tree().process_frame
	Net.chat_history = [{"camp": PieceInfo.Camp.RED, "text": "切场景时说的话"}]
	var game2 := await _open_game()
	_check(
		game2.get_node(CHAT_LOG).get_parsed_text().contains("切场景时说的话"),
		"进场时补显示切换途中到达的聊天"
	)

	# 旧版服务端：识别出「未知消息：chat」，锁掉输入并给出提示，且不盖掉回合提示
	_deliver("error", {"reason": "未知消息：chat"})
	await get_tree().process_frame
	_check(not Net.chat_supported, "识别出旧版服务端不支持聊天")
	_check(not game2.get_node(CHAT_INPUT).editable, "旧版服务端下聊天输入被锁掉")
	_check(game2.get_node(CHAT_LOG).get_parsed_text().contains("更新服务端"), "旧版服务端会给出更新提示")
	_check(game2.get_node("TurnLabel").text == turn_before, "旧服务端的聊天报错不会盖掉回合提示")

	# 返回主菜单：既切场景，也清掉联机状态
	var back2: Button = game2.get_node(BACK_BUTTON)
	var hit_back2: Control = await _click(back2)
	_check(hit_back2 == back2, "联机模式下「返回主菜单」也没被挡住（实际命中：%s）" % _name_of(hit_back2))
	await _settle()
	_check(
		get_tree().current_scene != null and get_tree().current_scene.scene_file_path == MAIN_MENU_SCENE,
		"联机模式按「返回主菜单」确实切回主菜单"
	)
	_check(not Net.in_game, "返回主菜单时清掉了联机对局状态")
	game2.queue_free()
	await get_tree().process_frame


# --- 工具 ---

## 在控件中心做一次真实鼠标点击，返回这次点击实际命中的控件。
##
## 必须走 push_input：emit_signal("pressed") 完全绕过 GUI 命中测试，
## 那种写法在「按钮被上层全屏容器挡住」时照样能通过，正是它漏掉了这个 bug。
## 命中测试一旦发现「中心点上的控件不是按钮自己」，就说明有东西盖在它上面。
func _click(control: Control) -> Control:
	var at := control.get_global_rect().get_center()

	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)
	var hit: Control = get_viewport().gui_get_hovered_control()

	for is_press in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = is_press
		button.position = at
		button.global_position = at
		get_viewport().push_input(button)
	await get_tree().process_frame
	return hit


func _name_of(control: Control) -> String:
	return "无" if control == null else String(control.name)


## 棋盘上某个格子在屏幕坐标里的中心。
func _cell_screen_pos(board: Board, col: int, row: int) -> Vector2:
	return board.global_position + board.cell_to_local(col, row)


## 按下鼠标左键（不松手），用于模拟长按。
func _press(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	get_viewport().push_input(press)
	await get_tree().process_frame


## 松开鼠标左键。
func _release(at: Vector2) -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	get_viewport().push_input(release)
	await get_tree().process_frame


## 递归收集一棵界面子树里的全部文字。
func _collect_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += (node as Label).text + "\n"
	elif node is RichTextLabel:
		text += (node as RichTextLabel).get_parsed_text() + "\n"
	for child in node.get_children():
		text += _collect_text(child)
	return text


## 把 change_scene_to_file 造出来的场景清掉。
##
## 它是 root 的后加入者，会画在测试节点**上面**，于是后面所有鼠标命中测试
## 都被它接走（实测命中 CenterContainer）。第一版就是栽在这里：
## 「联机模式返回主菜单」的两个断言因此假失败。
func _clear_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene == self:
		return
	get_tree().current_scene = null
	scene.queue_free()
	await get_tree().process_frame


func _open_game() -> Node:
	var game: Node = load(GAME_SCENE).instantiate()
	add_child(game)
	# 容器排版在 idle 阶段才结算，等两帧再断言尺寸与位置
	await get_tree().process_frame
	await get_tree().process_frame
	return game


## 棋盘**画出来**的那个正方形在屏幕上的矩形。
##
## 注意棋盘控件本身可以是任意矩形——它自己取长短边的较小值画正方形
## （见 Board._update_geometry），所以要按真正画出来的那个正方形来断言。
func _board_square_rect(game: Node) -> Rect2:
	var board: Board = game.get_node(BOARD)
	var side := minf(board.size.x, board.size.y)
	var origin := (board.size - Vector2(side, side)) * 0.5 + Vector2(board.frame_width, board.frame_width)
	return Rect2(board.global_position + origin, Vector2(side, side))


## 棋盘与聊天面板不能互相压住：容器排版一旦被改坏，这里就会红。
func _check_no_overlap(game: Node, scene: String) -> void:
	var board: Board = game.get_node(BOARD)
	var panel: Control = game.get_node(CHAT_PANEL)
	var drawn := _board_square_rect(game)
	_check(
		drawn.size.x > 300.0 and absf(drawn.size.x - drawn.size.y) < 1.0,
		"%s棋盘仍是够大的正方形（%.0f x %.0f）" % [scene, drawn.size.x, drawn.size.y]
	)
	if panel.visible:
		_check(drawn.end.x <= panel.get_global_rect().position.x + 0.5,
			"%s棋盘没有被聊天面板压住（棋盘右 %.0f，面板左 %.0f）"
				% [scene, drawn.end.x, panel.get_global_rect().position.x])


## change_scene_to_file 是延迟执行的，等两帧再断言。
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _fake_snapshot() -> Array:
	var session := Session.new(7)
	session.start()
	return session.to_snapshot()


## 模拟一次「服务端 → 客户端」收包，顺序与 Net.c_message 完全一致：
## 先更新 Net 的本地状态，再发信号给界面。
func _deliver(kind: String, payload: Dictionary) -> void:
	Net._apply_server_message(kind, payload)
	Net.server_message.emit(kind, payload)


func _check(condition: bool, title: String) -> void:
	if condition:
		_passed += 1
		print("  [通过] %s" % title)
	else:
		_failed += 1
		printerr("  [失败] %s" % title)
