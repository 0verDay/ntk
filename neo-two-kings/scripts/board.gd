class_name Board
extends Control

## 棋盘视图：把一个局面 Dictionary[Vector2i -> PieceInfo] 画出来，并处理鼠标交互。
##
## 它不持有游戏数据也不做任何棋规判断——局面由外部（单机的 Session 或联机的服务端快照）推入，
## 所以联机与单机走的是完全相同的渲染路径。
##
## 格子坐标 (col, row) 以左上角为原点。棋盘边长取可用空间的长宽较小值，因此控件本身可以是任意矩形。
## 格子不填色，只画蓝色格线与外框。

## 点击某个格子时发出，参数为格子坐标。
##
## 注意这是**松手时**才发出的：先按住看棋子卡片属于长按，
## 只有「按下后很快在同一格松手」才算点击，两种手势因此不会互相干扰。
signal cell_clicked(col: int, row: int)
## 长按某个格子达到 long_press_duration 时发出。
signal cell_long_pressed(col: int, row: int)
## 长按结束（松手，或指针移出原格）时发出。
signal cell_long_press_ended

## 棋盘边长上的格子数。
@export_range(2, 16, 1) var board_size: int = 7
## 格线与外框的颜色。
@export var line_color: Color = Color("1f5fd0")
## 内部格线宽度（像素）。
@export var line_width: float = 2.0
## 外框宽度（像素）。
@export var frame_width: float = 4.0
## 棋子死亡渐隐时长（秒）；设为 0 则立即消失。
@export_range(0.0, 2.0, 0.05) var death_fade_duration: float = Piece.DEATH_FADE_DURATION
## 按住多久算长按（秒）。
@export_range(0.1, 2.0, 0.05) var long_press_duration: float = 0.4

# 以下三项由 _update_geometry() 根据当前 size 计算。
var _cell_size: float = 0.0
var _origin: Vector2 = Vector2.ZERO
var _board_side: float = 0.0

# 当前局面：格子坐标 Vector2i -> PieceInfo（只读，外部不要直接改）
var _state: Dictionary = {}
# 视觉节点：格子坐标 Vector2i -> Piece
var _nodes: Dictionary = {}
# 鼠标当前所在格子，Vector2i(-1, -1) 表示不在棋盘上
var _hovered_cell := Vector2i(-1, -1)
# 当前选中的格子，Vector2i(-1, -1) 表示没有选中
var _selected_cell := Vector2i(-1, -1)
# 格子底色高亮（可移动格指示器）：格子坐标 Vector2i -> Color
var _highlights: Dictionary = {}

# --- 按压 / 长按状态 ---
# 当前按住不放的格子；Vector2i(-1, -1) 表示没有按压
var _press_cell := Vector2i(-1, -1)
# 本次按压已经持续了多久（秒）
var _press_elapsed := 0.0
# 本次按压是否已经升级成长按
var _long_pressed := false


func _ready() -> void:
	resized.connect(_on_resized)
	mouse_exited.connect(_on_mouse_exited)
	# 只有按住时才需要逐帧走表，平时把 _process 关掉
	set_process(false)
	queue_redraw()


func _on_resized() -> void:
	_layout_all()
	# 窗口缩放时鼠标没动，但仍需重算悬停
	set_hovered_cell(local_to_cell(get_local_mouse_position()))
	queue_redraw()


func _on_mouse_exited() -> void:
	set_hovered_cell(Vector2i(-1, -1))
	# 指针离开了棋盘，这次按压就作废（否则长按会在棋盘外继续倒计时）
	_cancel_press()


# --- 按压与长按 ---

## 长按计时。只在按住期间由 set_process(true) 驱动。
func _process(delta: float) -> void:
	if _press_cell.x < 0 or _long_pressed:
		return
	_press_elapsed += delta
	if _press_elapsed >= long_press_duration:
		_long_pressed = true
		cell_long_pressed.emit(_press_cell.x, _press_cell.y)


## 松手统一在 _input 里收尾，而不是 _gui_input：
## 按下之后指针完全可能拖到棋盘之外再松开，那样 release 根本不会送到本控件的 _gui_input，
## 按压状态就会一直挂着（长按会继续倒计时、点击也永远发不出去）。
func _input(event: InputEvent) -> void:
	if _press_cell.x < 0:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish_press()


# --- 几何 ---

## 单个格子的边长（像素）；布局尚未确定时为 0.0。
func get_cell_size() -> float:
	_update_geometry()
	return _cell_size


## 棋盘（不含外框）的边长（像素）。
func get_board_side() -> float:
	_update_geometry()
	return _board_side


## 格子坐标是否落在棋盘内。
func is_inside(cell: Vector2i) -> bool:
	return Rules.is_inside(cell, board_size)


## 格子中心在本控件内的局部坐标。
func cell_to_local(col: int, row: int) -> Vector2:
	_update_geometry()
	return _origin + Vector2((col + 0.5) * _cell_size, (row + 0.5) * _cell_size)


## 由本控件内的局部坐标求格子坐标；不在棋盘内时返回 Vector2i(-1, -1)。
func local_to_cell(local_pos: Vector2) -> Vector2i:
	_update_geometry()
	if _cell_size <= 0.0:
		return Vector2i(-1, -1)
	var col := int(floorf((local_pos.x - _origin.x) / _cell_size))
	var row := int(floorf((local_pos.y - _origin.y) / _cell_size))
	var cell := Vector2i(col, row)
	return cell if is_inside(cell) else Vector2i(-1, -1)


func _update_geometry() -> void:
	var side := minf(size.x, size.y)
	_board_side = maxf(side - frame_width * 2.0, 0.0)
	_origin = (size - Vector2(side, side)) * 0.5 + Vector2(frame_width, frame_width)
	_cell_size = _board_side / float(board_size) if board_size > 0 else 0.0


# --- 局面 ---

## 用新局面替换当前局面，并按差异同步视觉节点。
##
## 差异同步的要点：消失的与新增的格子先按「兵种+阵营」配对，能配上的视为同一个棋子移动，
## 直接复用原节点改位置，避免它先淡出再淡入；剩下的消失格走死亡渐隐，剩下的新增格新建节点。
## 因为同兵种同阵营的棋子在外观上无法区分，这种配对在视觉上总是正确的。
func set_state(new_state: Dictionary, animate_removals: bool = true) -> void:
	_update_geometry()

	var removed: Array[Vector2i] = []
	for cell in _nodes.keys():
		if not new_state.has(cell):
			removed.append(cell)
	var added: Array[Vector2i] = []
	for cell in new_state.keys():
		if not _nodes.has(cell):
			added.append(cell)

	var unmatched: Array[Vector2i] = []
	for cell in removed:
		var old_info: PieceInfo = _state.get(cell)
		var match_index := -1
		if old_info != null:
			for i in range(added.size()):
				var candidate: PieceInfo = new_state[added[i]]
				if candidate.kind == old_info.kind and candidate.camp == old_info.camp:
					match_index = i
					break
		if match_index < 0:
			unmatched.append(cell)
			continue
		var target: Vector2i = added[match_index]
		added.remove_at(match_index)
		var node: Piece = _nodes[cell]
		_nodes.erase(cell)
		_nodes[target] = node
		node.cell = target
		node.apply_info(new_state[target])

	for cell in unmatched:
		var node: Piece = _nodes[cell]
		_nodes.erase(cell)
		_retire(node, animate_removals)

	for cell in added:
		_nodes[cell] = _spawn(new_state[cell], cell)

	# 同格但数据变了（正常不会发生）也顺手刷新
	for cell in _nodes.keys():
		var node: Piece = _nodes[cell]
		var info: PieceInfo = new_state[cell]
		if node.info == null or not node.info.equals(info):
			node.apply_info(info)

	_state = new_state.duplicate()
	_layout_all()
	_refresh_visual_states()


## 当前局面（只读，不要直接修改；棋规函数也不会改它）。
func get_state() -> Dictionary:
	return _state


## 指定格子上的棋子数据；空位返回 null。
func get_piece_info_at(cell: Vector2i) -> PieceInfo:
	return _state.get(cell)


## 当前所有有棋子的格子。
func get_occupied_cells() -> Array:
	return _state.keys()


## 指定格子上的视觉节点；空位返回 null。主要用于调试、测试与后续动画。
func get_piece_node_at(cell: Vector2i) -> Piece:
	return _nodes.get(cell)


## 正在渐隐的棋子；它们已不在局面上，只是还在渲染。
func get_dying_pieces() -> Array[Piece]:
	var dying: Array[Piece] = []
	for child in get_children():
		if not (child is Piece):
			continue
		var piece: Piece = child
		if piece.is_dying:
			dying.append(piece)
	return dying


## 正在渐隐的棋子数量。
func get_dying_count() -> int:
	return get_dying_pieces().size()


# --- 视觉节点 ---

func _spawn(info: PieceInfo, cell: Vector2i) -> Piece:
	var node := Piece.new(info)
	node.cell = cell
	add_child(node)
	return node


## 立即摘除并释放，不留渲染。
func _discard(node: Piece) -> void:
	if node.get_parent() == self:
		remove_child(node)
	node.queue_free()


## 让棋子渐隐后再释放。
func _retire(node: Piece, fade: bool) -> void:
	if not fade or death_fade_duration <= 0.0:
		_discard(node)
		return
	# 移到子节点首位：兄弟之间它最先绘制，于是压在其它棋子下面（王的吃子不会盖住王）。
	# 这里不能用负 z_index——那会让它画到白色 Background 之后，整枚棋子不可见。
	if node.get_parent() == self:
		move_child(node, 0)
	node.play_death(death_fade_duration)


func _layout_all() -> void:
	_update_geometry()
	if _cell_size <= 0.0:
		return
	for cell in _nodes.keys():
		_layout_node(_nodes[cell], cell)
	# 渐隐中的棋子也要跟住窗口缩放，否则缩放时它们会错位
	for node in get_dying_pieces():
		_layout_node(node, node.cell)


func _layout_node(node: Piece, cell: Vector2i) -> void:
	node.position = _origin + Vector2(cell.x, cell.y) * _cell_size
	node.size = Vector2(_cell_size, _cell_size)
	node.set_display_size(_cell_size)


# --- 交互状态 ---

## 鼠标当前所在格子；不在棋盘上时为 Vector2i(-1, -1)。
func get_hovered_cell() -> Vector2i:
	return _hovered_cell


## 设置悬停格子，并同步棋子的悬停高亮。
func set_hovered_cell(cell: Vector2i) -> void:
	var normalized := cell if is_inside(cell) else Vector2i(-1, -1)
	if normalized == _hovered_cell:
		return
	_hovered_cell = normalized
	_refresh_visual_states()


## 当前选中的格子；没有选中时返回 Vector2i(-1, -1)。
func get_selected_cell() -> Vector2i:
	return _selected_cell


## 设置选中的格子，并同步棋子的选中高亮。
func set_selected_cell(cell: Vector2i) -> void:
	var normalized := cell if is_inside(cell) else Vector2i(-1, -1)
	if normalized == _selected_cell:
		return
	_selected_cell = normalized
	_refresh_visual_states()


## 设置格子底色高亮，参数为 {Vector2i: Color}；传空字典即全部清除。
func set_cell_highlights(highlights: Dictionary) -> void:
	_highlights = highlights.duplicate()
	queue_redraw()


## 当前被高亮的格子坐标。
func get_highlighted_cells() -> Array:
	return _highlights.keys()


func clear_cell_highlights() -> void:
	if _highlights.is_empty():
		return
	_highlights.clear()
	queue_redraw()


func _refresh_visual_states() -> void:
	for cell in _nodes.keys():
		var node: Piece = _nodes[cell]
		node.set_hovered(cell == _hovered_cell)
		node.set_selected(cell == _selected_cell)


# --- 绘制 ---

func _draw() -> void:
	_update_geometry()
	if _cell_size <= 0.0:
		return

	var top_left := _origin
	var bottom_right := _origin + Vector2(_board_side, _board_side)
	var cell_vec := Vector2(_cell_size, _cell_size)

	# 格子底色高亮（可移动格指示器），画在格线之下
	for cell in _highlights.keys():
		draw_rect(Rect2(_origin + Vector2(cell.x, cell.y) * _cell_size, cell_vec), _highlights[cell], true)

	# 内部格线
	for i in range(1, board_size):
		var offset := i * _cell_size
		draw_line(
			Vector2(top_left.x + offset, top_left.y),
			Vector2(top_left.x + offset, bottom_right.y),
			line_color, line_width, true
		)
		draw_line(
			Vector2(top_left.x, top_left.y + offset),
			Vector2(bottom_right.x, top_left.y + offset),
			line_color, line_width, true
		)

	# 外框
	draw_rect(Rect2(top_left, Vector2(_board_side, _board_side)), line_color, false, frame_width, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# 棋子 mouse_filter 为 IGNORE，所以鼠标划过棋子时事件仍然落到棋盘上
		set_hovered_cell(local_to_cell(event.position))
		# 按住期间挪到别的格子：这次按压作废（长按随之结束），避免误触
		if _press_cell.x >= 0 and _hovered_cell != _press_cell:
			_cancel_press()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := local_to_cell(event.position)
		if cell.x >= 0:
			_begin_press(cell)
			accept_event()


func _begin_press(cell: Vector2i) -> void:
	_press_cell = cell
	_press_elapsed = 0.0
	_long_pressed = false
	set_process(true)


## 松手：短按发 cell_clicked，长按只发 cell_long_press_ended。
##
## 这里不需要释放位置：指针一旦离开原格，motion 分支早就把按压取消掉了，
## 所以能走到这儿就说明松手时指针还在按下的那一格上。
func _finish_press() -> void:
	if _press_cell.x < 0:
		return
	var cell := _press_cell
	var was_long := _long_pressed
	_clear_press()
	if was_long:
		cell_long_press_ended.emit()
	else:
		cell_clicked.emit(cell.x, cell.y)


## 取消按压（指针移出原格或离开棋盘）：不发 cell_clicked，但长按要正常收尾。
func _cancel_press() -> void:
	if _press_cell.x < 0:
		return
	var was_long := _long_pressed
	_clear_press()
	if was_long:
		cell_long_press_ended.emit()


func _clear_press() -> void:
	_press_cell = Vector2i(-1, -1)
	_press_elapsed = 0.0
	_long_pressed = false
	set_process(false)


## 当前是否正在长按某一格（供测试与调试查询）。
func is_long_pressing() -> bool:
	return _press_cell.x >= 0 and _long_pressed
