extends Control

## 游玩场景：把局面渲染出来、处理选子与走子。
##
## 它自己不持有棋规状态，只做两件事：
##   - 单机模式：驱动一个本地 Session（权威），走完把 session.state 推给 Board；
##   - 联机模式：把走子意图发给服务端，收到服务端快照后再推给 Board（服务端权威）。
## 两条路径的渲染完全一致，因为 Board 只认局面。

enum Mode { OFFLINE, ONLINE }

## 可移动格的底色。
const MOVE_HINT_COLOR := Color(0.121569, 0.372549, 0.815686, 0.13)
## 可吃子格（王的吃子）的底色。
const CAPTURE_HINT_COLOR := Color(0.8, 0.176471, 0.141176, 0.22)

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _board: Board = $BoardMargin/Board
@onready var _turn_label: Label = $TurnLabel
@onready var _back_button: Button = $BackButton

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


func _ready() -> void:
	_board.cell_clicked.connect(_on_cell_clicked)
	_back_button.pressed.connect(_on_back_pressed)
	if Net.in_game:
		_enter_online()
	else:
		start_offline()


# --- 模式 ---

## 开一局单机对局（红绿双方都在本机轮流操作）。
func start_offline() -> void:
	_mode = Mode.OFFLINE
	_online_finished = false
	_back_button.visible = false
	_session = Session.new(_board.board_size)
	_session.start()
	_apply_state(_session.state, _session.current_camp)


## 联机模式：从 Net 里取出服务端指定的阵营与首个局面。
func _enter_online() -> void:
	_mode = Mode.ONLINE
	_online_finished = false
	_back_button.visible = true
	_my_camp = Net.my_camp
	_session = null
	Net.server_message.connect(_on_server_message)
	_apply_snapshot(Net.last_snapshot)


## 测试或外部显式接管用：指定我执哪一方并推入首个快照。
func setup_online(my_camp: PieceInfo.Camp, snapshot: Array) -> void:
	_mode = Mode.ONLINE
	_online_finished = false
	_back_button.visible = true
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
		"opponent_left", "room_closed":
			_end_online(str(payload.get("reason", "对手已离开对局")))
		"error":
			_turn_label.text = str(payload.get("reason", "操作无效"))
			await get_tree().create_timer(1.5).timeout
			if is_inside_tree() and not _online_finished:
				_update_turn_label()


func _end_online(message: String) -> void:
	_online_finished = true
	_clear_selection()
	_turn_label.text = message
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
