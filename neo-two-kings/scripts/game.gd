extends Control

## 游玩场景：把局面渲染出来、处理选子与走子，另外带一个聊天面板。
##
## 它自己不持有棋规状态，只做两件事：
##   - 单机模式：驱动一个本地 Session（权威），走完把 session.state 推给 Board；
##   - 联机模式：把走子意图发给服务端，收到服务端快照后再推给 Board（服务端权威）。
## 两条路径的渲染完全一致，因为 Board 只认局面。
##
## 聊天也分两条路径：单机直接写本机记录（两人共用一块屏幕），
## 联机把消息交给服务端转发，再按服务端回显上屏——自己发的消息也不抢先本地显示，
## 这样双方的顺序完全一致，与走子「服务端权威」的做法保持同一套逻辑。

enum Mode { OFFLINE, ONLINE }

## 可移动格的底色。
const MOVE_HINT_COLOR := Color(0.121569, 0.372549, 0.815686, 0.13)
## 可吃子格（王的吃子）的底色。
const CAPTURE_HINT_COLOR := Color(0.8, 0.176471, 0.141176, 0.22)

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## 聊天记录里最多保留多少行，超出后从最旧的开始丢弃，避免长局把内存撑起来。
const CHAT_LOG_MAX_LINES := 200
## 系统提示（不是玩家发言）的文字颜色。
const CHAT_SYSTEM_COLOR := Color(0.541176, 0.560784, 0.6)

## 界面四周统一留的空白（指南卡片与聊天面板都用它）。
const LAYOUT_MARGIN := 32.0
## 内容区上边距：给顶栏（回合提示 + 两个按钮）让位。
const CONTENT_TOP := 96.0
## 卡片内边距（与 _build_guide_card 里的 margin 保持一致）。
const GUIDE_CARD_PADDING := 16.0
## 卡片宽度小于这个值就不显示了——那点宽度只够把汉字竖着排，没有可读性。
const GUIDE_CARD_MIN_WIDTH := 90.0
## 卡片各段文字的字号：棋子字 / 引导句 / 正文。
## 正文会按可用高度自动调小，另外两个跟着一起缩（见 _fill_guide_card）。
const GUIDE_CARD_POINT_SIZE := 13
const GUIDE_CARD_MIN_POINT_SIZE := 9
const GUIDE_CARD_SYMBOL_EXTRA := 13
const GUIDE_CARD_TAGLINE_EXTRA := 2
## 说明实在放不下时，末尾接这一句指向完整指南，而不是把句子切成两半。
const GUIDE_CARD_POINTER_TEXT := "…（完整说明见主菜单「棋子指南」）"
## 字体度量算出来的高度留一点余量，免得最后一行被裁。
const GUIDE_CARD_HEIGHT_SAFETY := 1.12

## 聊天面板与棋盘之间的空隙：面板只占棋盘右边的空当，绝不压住棋盘。
const CHAT_PANEL_GAP := 16.0
## 聊天面板的可用宽度下限。棋盘右侧实在挤不下时会压住棋盘一点，并打一条警告。
const CHAT_PANEL_MIN_WIDTH := 240.0

@onready var _board: Board = $ContentMargin/BoardArea/Board
@onready var _turn_label: Label = $TurnLabel
@onready var _back_button: Button = $BackButton
@onready var _chat_toggle_button: Button = $ChatToggleButton
@onready var _chat_panel: PanelContainer = $ChatPanel
@onready var _chat_log: RichTextLabel = $ChatPanel/ChatMargin/ChatColumn/ChatLog
@onready var _chat_input: LineEdit = $ChatPanel/ChatMargin/ChatColumn/ChatInputRow/ChatInput
@onready var _chat_send_button: Button = $ChatPanel/ChatMargin/ChatColumn/ChatInputRow/ChatSendButton
@onready var _chat_close_button: Button = $ChatPanel/ChatMargin/ChatColumn/ChatHeader/ChatCloseButton

var _mode: Mode = Mode.OFFLINE
# 单机模式下的权威流程；联机模式为 null
var _session: Session = null
# 联机模式下我执哪一方
var _my_camp: PieceInfo.Camp = PieceInfo.Camp.RED
# 当前该谁走（两种模式都由外部推入）
var _current_camp: PieceInfo.Camp = PieceInfo.Camp.RED
# 当前选中的格子，Vector2i(-1, -1) 表示未选中
var _selected := Vector2i(-1, -1)
# 联机对局是否已经结束（对手离开等），结束后禁止操作
var _online_finished := false
# 聊天面板收起时收到的新消息条数，显示在「聊天」按钮上做提醒
var _unread_chat := 0
# 长按棋子时弹出的指南卡片（整个场景共用一个，内容按棋子重填）
var _guide_card: PanelContainer = null
var _guide_card_box: VBoxContainer = null
# 卡片当前显示的是哪种棋子；-1 表示没显示
var _guide_card_kind := -1
# 重算矩形时会顺带重排内容，用它挡住重入
var _updating_guide_card := false


func _ready() -> void:
	# 长度上限只在这里设一次，避免场景文件里的写死值与 GameServer 里的常量各说各话
	_chat_input.max_length = GameServer.CHAT_MAX_LENGTH

	_build_guide_card()

	_board.cell_clicked.connect(_on_cell_clicked)
	_board.cell_long_pressed.connect(_on_cell_long_pressed)
	_board.cell_long_press_ended.connect(_hide_guide_card)
	_back_button.pressed.connect(_on_back_pressed)
	_chat_toggle_button.pressed.connect(_toggle_chat)
	_chat_close_button.pressed.connect(_toggle_chat)
	_chat_send_button.pressed.connect(_on_chat_submit)
	_chat_input.text_submitted.connect(_on_chat_text_submitted)

	# 聊天面板与长按卡片都是按棋盘位置手动摆放的，棋盘一动就得重算
	resized.connect(_update_layout_rects)
	_board.resized.connect(_update_layout_rects)
	_update_layout_rects()

	if Net.in_game:
		_enter_online()
	else:
		start_offline()


# --- 模式 ---

## 开一局单机对局（红绿双方都在本机轮流操作）。
func start_offline() -> void:
	_mode = Mode.OFFLINE
	_online_finished = false
	# 单机是两人共用一块屏幕，聊天没有意义，默认收起把宽度让给棋盘
	_set_chat_panel_visible(false)
	_session = Session.new(_board.board_size)
	_session.start()
	_apply_state(_session.state, _session.current_camp)
	_append_system_chat("本机对局：聊天只显示在本机。")


## 联机模式：从 Net 里取出服务端指定的阵营与首个局面。
func _enter_online() -> void:
	_mode = Mode.ONLINE
	_online_finished = false
	_my_camp = Net.my_camp
	_session = null
	Net.server_message.connect(_on_server_message)
	Net.chat_unsupported.connect(_on_chat_unsupported)
	_set_chat_panel_visible(true)
	_apply_snapshot(Net.last_snapshot)
	# 消息可能在场景切换途中就到达（那时本场景还没 _ready、接不到信号），
	# 所以这里按 Net 里存下的记录补一次聊天内容
	for entry in Net.chat_history:
		_append_chat(int(entry["camp"]), str(entry["text"]))
	if not Net.chat_supported:
		_on_chat_unsupported()


## 测试或外部显式接管用：指定我执哪一方并推入首个快照。
func setup_online(my_camp: PieceInfo.Camp, snapshot: Array) -> void:
	_mode = Mode.ONLINE
	_online_finished = false
	_my_camp = my_camp
	_session = null
	_apply_snapshot(snapshot)


func get_mode() -> Mode:
	return _mode


func get_my_camp() -> PieceInfo.Camp:
	return _my_camp


func get_current_camp() -> PieceInfo.Camp:
	return _current_camp


# --- 局面 ---

func _apply_state(state: Dictionary, current_camp: PieceInfo.Camp) -> void:
	_current_camp = current_camp
	_clear_selection()
	_board.set_state(state)
	_update_turn_label()


## 联机模式：应用服务端下发的快照 [棋盘边长, 当前回合, [[x,y,兵种,阵营], ...]]
func _apply_snapshot(snapshot: Array) -> void:
	if snapshot.size() < 3:
		return
	_apply_state(Session.state_from_snapshot(snapshot), snapshot[1])


func _update_turn_label() -> void:
	var side := "红" if _current_camp == PieceInfo.Camp.RED else "绿"
	if _mode == Mode.OFFLINE:
		_turn_label.text = "%s方回合" % side
	else:
		var mine := "你" if _current_camp == _my_camp else "对手"
		_turn_label.text = "%s方回合（%s）" % [side, mine]
	_turn_label.add_theme_color_override("font_color", Piece.CAMP_COLORS.get(_current_camp, Color.BLACK))


# --- 服务端消息 ---

func _on_server_message(kind: String, payload: Dictionary) -> void:
	match kind:
		"state":
			_apply_snapshot(payload.get("snapshot", []))
		"chat":
			_append_chat(int(payload.get("camp", PieceInfo.Camp.RED)), str(payload.get("text", "")))
		"opponent_left", "room_closed":
			_end_online(str(payload.get("reason", "对手已离开对局")))
		"error":
			var reason := str(payload.get("reason", "操作无效"))
			# 旧版服务端对 chat 的「未知消息」回应已经由 Net 变成了聊天不可用提示，
			# 不要再拿它把回合提示盖掉
			if not Net.chat_supported and reason == "未知消息：chat":
				return
			_turn_label.text = reason
			await get_tree().create_timer(1.5).timeout
			if is_inside_tree() and not _online_finished:
				_update_turn_label()


func _end_online(message: String) -> void:
	_online_finished = true
	_clear_selection()
	_turn_label.text = message
	_disable_chat_input("对手已离开，聊天已关闭")
	Net.leave_room()


func _on_back_pressed() -> void:
	if _mode == Mode.ONLINE:
		Net.leave_room()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# --- 选子与走子 ---

## 现在轮到我操作吗？是则返回我执的阵营，否则返回 -1。
## 单机模式下红绿都由本机操作，所以永远轮得到。
func _active_camp() -> int:
	if _online_finished:
		return -1
	if _mode == Mode.OFFLINE:
		return _current_camp
	return _my_camp if _my_camp == _current_camp else -1


func _on_cell_clicked(col: int, row: int) -> void:
	var active := _active_camp()
	if active < 0:
		return
	var cell := Vector2i(col, row)
	var info := _board.get_piece_info_at(cell)

	# 还没选中：只能选中自己能操作的棋子
	if _selected.x < 0:
		if info != null and int(info.camp) == active:
			_select(cell)
		return

	# 点回已选中的棋子：取消选中
	if cell == _selected:
		_clear_selection()
		return

	# 点到可走的位置：走子
	if _can_move(_selected, cell):
		_request_move(_selected, cell)
		return

	# 点到别的己方棋子：改选
	if info != null and int(info.camp) == active:
		_select(cell)


## 本地合法性预判。单机直接问 Session；联机也做同样的判断用于指示器，但真正的判定在服务端。
func _can_move(from: Vector2i, to: Vector2i) -> bool:
	if _mode == Mode.OFFLINE:
		return _session != null and _session.can_move(from, to)
	var info := _board.get_piece_info_at(from)
	if info == null or info.camp != _current_camp:
		return false
	return to in Rules.reachable_cells(_board.get_state(), from, _board.board_size)


func _request_move(from: Vector2i, to: Vector2i) -> void:
	_clear_selection()
	if _mode == Mode.OFFLINE:
		if _session.try_move(from, to):
			_apply_state(_session.state, _session.current_camp)
		return
	# 联机：只把意图发给服务端，等它推回新局面。本地不抢先改棋盘，避免与服务端不一致。
	Net.request_move(from, to)


func _select(cell: Vector2i) -> void:
	_selected = cell
	_board.set_selected_cell(cell)
	_refresh_hints()


func _clear_selection() -> void:
	_selected = Vector2i(-1, -1)
	_board.set_selected_cell(Vector2i(-1, -1))
	_refresh_hints()


## 把当前选中棋子的全部合法落点画到棋盘上。
func _refresh_hints() -> void:
	if _selected.x < 0:
		_board.clear_cell_highlights()
		return
	var hints := {}
	for cell in Rules.reachable_cells(_board.get_state(), _selected, _board.board_size):
		hints[cell] = CAPTURE_HINT_COLOR if _board.get_piece_info_at(cell) != null else MOVE_HINT_COLOR
	_board.set_cell_highlights(hints)


# --- 布局 ---

## 棋盘位置一变（窗口缩放、聊天面板收放）就重算两个浮动面板的矩形。
func _update_layout_rects() -> void:
	_update_chat_panel_rect()
	_update_guide_card_rect()


## 聊天面板固定在棋盘右侧的空当里，绝不压住棋盘。
##
## 它**不参与** ContentMargin 的容器排版，就是为了「开关聊天时棋盘纹丝不动」：
## 之前它和棋盘同在一条 HBoxContainer 里，一展开就把棋盘挤得往左跳（约 170px）。
## 代价是位置要自己算，所以这里跟着棋盘实时重排。
func _update_chat_panel_rect() -> void:
	if _chat_panel == null or not is_inside_tree():
		return
	var board_right := _board_left_edge() + minf(_board.size.x, _board.size.y)
	var right := size.x - LAYOUT_MARGIN
	var left := maxf(board_right + CHAT_PANEL_GAP, 0.0)
	if right - left < CHAT_PANEL_MIN_WIDTH:
		# 棋盘右侧实在挤不下（窄窗口）。棋盘不能动，只能让面板压住棋盘一点，
		# 至少保证它还能用；1280×720 及更宽的窗口不会走到这里。
		push_warning(
			"棋盘右侧只剩 %.0f px，聊天面板会压住棋盘右边缘" % (right - board_right - CHAT_PANEL_GAP)
		)
		left = maxf(right - CHAT_PANEL_MIN_WIDTH, 0.0)
	_chat_panel.position = Vector2(left, CONTENT_TOP)
	_chat_panel.size = Vector2(right - left, size.y - CONTENT_TOP - LAYOUT_MARGIN)


## 棋盘**画出来**的那条左边缘在屏幕上的 x。
##
## 取的是正方形本身而不是 Board 控件的左边缘：控件可以是任意矩形，
## 正方形在控件里居中（见 Board._update_geometry），空出来的那部分才是「空白区」。
## 聊天面板与长按卡片都以它为基准，所以棋盘不动它们就不会乱跑。
func _board_left_edge() -> float:
	var side := minf(_board.size.x, _board.size.y)
	var inset_x := (_board.size.x - side) * 0.5 + _board.frame_width
	return _board.global_position.x + inset_x


# --- 长按棋子看指南卡片 ---

## 建一次卡片骨架，之后每次长按只换里面的文字。
##
## 卡片固定在棋盘左侧的空白区里：左边缘距离屏幕左边 LAYOUT_MARGIN，
## 右边缘距离棋盘左边缘 LAYOUT_MARGIN，上下铺满整个屏幕（各留 LAYOUT_MARGIN）。
## 尺寸每次显示时按棋盘的真实位置重算，所以聊天面板收放、窗口缩放都能跟上。
func _build_guide_card() -> void:
	_guide_card = PanelContainer.new()
	_guide_card.name = "GuideCard"
	_guide_card.visible = false
	# 卡片只用来「看」：永远不参与命中测试，
	# 这样它既不会挡住棋盘，也不会在长按松手时把鼠标事件抢走。
	_guide_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guide_card.clip_contents = true
	_guide_card.add_theme_stylebox_override("panel", _make_guide_card_style())
	add_child(_guide_card)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 16)

	# 中间夹一层 ScrollContainer 是为了「切断最小尺寸」：
	# 自动换行的 Label 在宽度还没确定时，最小高度是按每行一个字算出来的（实测能到 4600+px），
	# 容器会把这个最小尺寸一路顶上去，卡片就被撑成一根长条。
	# ScrollContainer 自身的最小尺寸很小，卡片才能保持我们指定的高度；
	# 内容太长时它负责裁剪（卡片不参与命中测试，所以滚不动，只是裁掉）。
	var scroll := ScrollContainer.new()
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.add_child(margin)
	_guide_card.add_child(scroll)

	_guide_card_box = VBoxContainer.new()
	_guide_card_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guide_card_box.add_theme_constant_override("separation", 8)
	margin.add_child(_guide_card_box)

	# 棋盘位置会随聊天面板收放、窗口缩放而变，跟着重算卡片矩形
	resized.connect(_update_guide_card_rect)
	_board.resized.connect(_update_guide_card_rect)


func _on_cell_long_pressed(col: int, row: int) -> void:
	var info := _board.get_piece_info_at(Vector2i(col, row))
	if info == null:
		return
	_show_guide_card(info.kind)


func _show_guide_card(kind: int) -> void:
	var note := PieceGuide.note_for(kind)
	if note.is_empty():
		return

	# 先定矩形再填内容：字号要按卡片最终的宽高来算
	_update_guide_card_rect()
	if _guide_card.size.x < GUIDE_CARD_MIN_WIDTH:
		# 棋盘左边实在没有空间（例如窄窗口里聊天面板还开着），
		# 硬显示只会得到一列竖排的汉字，还不如不显示
		push_warning("棋盘左侧只剩 %.0f px 空白，棋子卡片太窄，已跳过显示" % _guide_card.size.x)
		_guide_card.visible = false
		return
	_fill_guide_card(note)
	_guide_card_kind = kind
	_guide_card.visible = true


func _hide_guide_card() -> void:
	if _guide_card != null:
		_guide_card.visible = false
		_guide_card_kind = -1


## 卡片矩形：左侧空白区、上下铺满屏幕。
func _update_guide_card_rect() -> void:
	if _guide_card == null or not is_inside_tree() or _updating_guide_card:
		return
	_updating_guide_card = true
	var board_left := _board_left_edge()
	_guide_card.position = Vector2(LAYOUT_MARGIN, LAYOUT_MARGIN)
	_guide_card.size = Vector2(
		board_left - LAYOUT_MARGIN * 2.0,
		size.y - LAYOUT_MARGIN * 2.0
	)
	# 尺寸变了字号也得重算（例如卡片正显示时收起/展开聊天面板）
	if _guide_card.visible:
		_fill_guide_card(PieceGuide.note_for(_guide_card_kind))
	_updating_guide_card = false


## 按棋子重填卡片内容。
##
## 卡片宽度被棋盘左侧的空白区锁死（窄窗口下可能只有一百多像素），而每种棋子的说明有 4~6 条，
## 所以这里分两种情况：
##   1. 有一个字号能把整段说明放进去 → 用其中最大的那个字号，全写出来；
##   2. 缩到最小字号还是放不下 → 用最小字号，能放几条放几条，末尾接一句指向完整指南。
## 两种情况都不会出现「一句话被拦腰截断」。
##
## 高度是用 Font.get_multiline_string_size 直接量出来的，不依赖「先排版再测量」，
## 所以不需要等一帧、也不会因为测量时机不同而抖来抖去。
func _fill_guide_card(note: Dictionary) -> void:
	var kind: int = note["kind"]
	var symbol := PieceGuide.symbol_of(kind)
	var tagline := str(note.get("tagline", ""))
	var points: Array = note.get("points", [])

	var width := maxf(_guide_card.size.x - GUIDE_CARD_PADDING * 2.0, 1.0)
	var height := maxf(_guide_card.size.y - GUIDE_CARD_PADDING * 2.0, 1.0)

	# 先造一个探针标签拿主题字体，量完高度再决定最终字号
	var probe := _make_guide_card_label(symbol, GUIDE_CARD_POINT_SIZE, Color.BLACK)
	var font := probe.get_theme_font("font")
	probe.free()

	var size := GUIDE_CARD_MIN_POINT_SIZE
	var shown := points.size()
	var with_pointer := false

	var all_fit := false
	for candidate in range(GUIDE_CARD_POINT_SIZE, GUIDE_CARD_MIN_POINT_SIZE - 1, -1):
		if _card_text_height(font, width, candidate, symbol, tagline, points, points.size(), false) <= height:
			size = candidate
			all_fit = true
			break
	if not all_fit:
		shown = 0
		with_pointer = true
		while shown < points.size():
			if _card_text_height(font, width, size, symbol, tagline, points, shown + 1, true) > height:
				break
			shown += 1

	for child in _guide_card_box.get_children():
		# 先从容器里摘掉再释放，否则旧的说明会和新的一起排版一帧
		_guide_card_box.remove_child(child)
		child.queue_free()

	var symbol_label := _make_guide_card_label(
		symbol, size + GUIDE_CARD_SYMBOL_EXTRA, Piece.CAMP_COLORS.get(PieceInfo.Camp.RED, Color.BLACK)
	)
	var tagline_label := _make_guide_card_label(
		tagline, size + GUIDE_CARD_TAGLINE_EXTRA, PieceGuide.ACCENT_COLOR
	)
	_guide_card_box.add_child(symbol_label)
	_guide_card_box.add_child(tagline_label)

	var point_labels: Array[Label] = []
	for index in range(shown):
		var label := _make_guide_card_label("・%s" % points[index], size, PieceGuide.BODY_COLOR)
		_guide_card_box.add_child(label)
		point_labels.append(label)
	if with_pointer:
		_guide_card_box.add_child(_make_guide_card_label(
			GUIDE_CARD_POINTER_TEXT, size, PieceGuide.ACCENT_COLOR
		))

	_apply_card_font_size(size, symbol_label, tagline_label, point_labels)


## 量出「棋子字 + 引导句 + 前 count 条说明（+ 指路那一句）」在当前宽度下需要多高。
func _card_text_height(
	font: Font, width: float, point_size: int, symbol: String, tagline: String,
	points: Array, count: int, with_pointer: bool
) -> float:
	var total := _text_height(font, symbol, width, point_size + GUIDE_CARD_SYMBOL_EXTRA)
	total += _text_height(font, tagline, width, point_size + GUIDE_CARD_TAGLINE_EXTRA)
	for index in range(count):
		total += _text_height(font, "・%s" % points[index], width, point_size)
	if with_pointer:
		total += _text_height(font, GUIDE_CARD_POINTER_TEXT, width, point_size)
	var rows := 2 + count + (1 if with_pointer else 0)
	total += float(rows - 1) * float(_guide_card_box.get_theme_constant("separation"))
	return total * GUIDE_CARD_HEIGHT_SAFETY


func _text_height(font: Font, text: String, width: float, font_size: int) -> float:
	return font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size).y


func _apply_card_font_size(point_size: int, symbol_label: Label, tagline_label: Label, point_labels: Array[Label]) -> void:
	symbol_label.add_theme_font_size_override("font_size", point_size + GUIDE_CARD_SYMBOL_EXTRA)
	tagline_label.add_theme_font_size_override("font_size", point_size + GUIDE_CARD_TAGLINE_EXTRA)
	for label in point_labels:
		label.add_theme_font_size_override("font_size", point_size)


## 卡片正文当前用的字号（供测试检查「窄的时候确实缩了」）。
func get_guide_card_point_font_size() -> int:
	if _guide_card_box == null or _guide_card_box.get_child_count() == 0:
		return 0
	var symbol_label: Label = _guide_card_box.get_child(0)
	return symbol_label.get_theme_font_size("font_size") - GUIDE_CARD_SYMBOL_EXTRA


func _make_guide_card_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_guide_card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.964706, 0.972549, 0.984314, 1)
	style.set_border_width_all(1)
	style.border_color = Color(0.121569, 0.372549, 0.815686, 0.25)
	style.set_corner_radius_all(10)
	return style


# --- 聊天 ---

## 展开 / 收起聊天面板。收起后棋盘会把让出来的宽度吃掉。
func _toggle_chat() -> void:
	_set_chat_panel_visible(not _chat_panel.visible)
	if _chat_panel.visible:
		_chat_input.grab_focus()
	else:
		# 收起时交还焦点，免得回车还在往聊天框里发消息
		_chat_input.release_focus()


func _set_chat_panel_visible(value: bool) -> void:
	_chat_panel.visible = value
	if value:
		_unread_chat = 0
		_update_chat_panel_rect()
	_update_chat_toggle_text()


func _update_chat_toggle_text() -> void:
	var label := "聊天"
	if not _chat_panel.visible and _unread_chat > 0:
		label = "聊天 (%d)" % _unread_chat
	_chat_toggle_button.text = label


func _on_chat_text_submitted(_text: String) -> void:
	_on_chat_submit()


func _on_chat_submit() -> void:
	var text := GameServer.sanitize_chat(_chat_input.text)
	if text.is_empty():
		return
	_chat_input.clear()
	if _mode == Mode.OFFLINE:
		# 单机：两人共用一块屏幕，没有网络可发，直接落到本机记录
		_append_chat(_current_camp, text)
		return
	if not Net.chat_supported:
		_append_system_chat("当前服务端不支持聊天，请更新服务端后再试。")
		return
	# 联机：不本地抢先上屏，等服务端回显，保证双方顺序一致
	Net.send_chat(text)


## 收到旧版服务端的「不认识 chat」回应：锁掉输入框并说明原因。
func _on_chat_unsupported() -> void:
	_disable_chat_input("服务端版本过旧，不支持聊天")
	_append_system_chat("当前服务端不认识聊天消息，需要更新服务端之后才能联机聊天。")
	_set_chat_panel_visible(true)


func _disable_chat_input(placeholder: String) -> void:
	_chat_input.editable = false
	_chat_send_button.disabled = true
	_chat_input.placeholder_text = placeholder


## 把一条聊天消息写进记录。camp 是发言方阵营，用来取名字与颜色。
func _append_chat(camp: int, raw_text: String) -> void:
	var text := GameServer.sanitize_chat(raw_text)
	if text.is_empty():
		return
	var who := "红方" if camp == PieceInfo.Camp.RED else "绿方"
	if _mode == Mode.ONLINE:
		who = "我" if camp == _my_camp else "对手"
	_append_chat_line(who, Piece.CAMP_COLORS.get(camp, Color.BLACK), text)
	if not _chat_panel.visible:
		_unread_chat += 1
		_update_chat_toggle_text()


func _append_chat_line(who: String, who_color: Color, text: String) -> void:
	_chat_log.append_text("[color=#%s][b]%s[/b][/color]：%s\n" % [
		who_color.to_html(false), _escape_bbcode(who), _escape_bbcode(text),
	])
	_trim_chat_log()


func _append_system_chat(text: String) -> void:
	_chat_log.append_text("[color=#%s][i]%s[/i][/color]\n" % [
		CHAT_SYSTEM_COLOR.to_html(false), _escape_bbcode(text),
	])
	_trim_chat_log()


## 记录太长时从最旧的开始丢，避免一局打很久把行数堆到失控。
func _trim_chat_log() -> void:
	while _chat_log.get_paragraph_count() > CHAT_LOG_MAX_LINES:
		_chat_log.remove_paragraph(0)


## 玩家输入里的 [ 必须转义，否则会被 RichTextLabel 当成 BBCode 标签解析。
static func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
