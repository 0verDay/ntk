class_name GuideDemo
extends Control

## 指南里那张会动的棋盘：把 GuideDemos 算出来的帧画出来，并自动循环播放。
##
## 它只做三件事——画帧、用一个 Tween 推进进度、在别人看不见的时候停下来。
## **不含任何棋规判断，也不做任何演算**：画什么完全来自 GuideDemos（也就是 JSON 里写死的帧）。
##
## 「看哪几格」由每一帧自己的那个矩形决定（作者在 `tools/demos/*.py` 里写 `view=rect(...)`，
## 不写就按这一帧的内容自动推）——见 GuideDemos.view_of 与 canvas_of：舞台整段只有一个
## （所有视口里最大的那个），比它小的镜头**居中**放在舞台里，所以镜头移动不会让文字重排。
##
## 配色与字形刻意和真实棋盘同一套来源（Piece.CAMP_COLORS、Board.line_color、
## PieceGuide 的三种文字色），所以改了棋盘主题，指南里的演示会跟着变，
## 但演示并不复用 Board / Piece 节点——对局视图的职责不被污染。

## 演示棋盘和真实棋盘用同一套配色来源。
## 外框色刻意与 Board.line_color 的默认值写成同一个值：跨类取常量在 GDScript 里
## 编译期解析不到（Board 是 Control 脚本，不是纯常量容器），而为了一个颜色去 new 一个
## Board 节点更不划算。改棋盘线色时请一并改这里。
const LINE_COLOR := Color("1f5fd0")
const GRID_COLOR := Color("1f5fd0", 0.16)

## 高亮的格子（作者在编辑器里点出来的那些）。
const ZONE_COLOR := Color("f0a020", 0.16)
const ZONE_BORDER_COLOR := Color("f0a020", 0.75)
## 箭头的三种颜色：与编辑器里的「移动 / 攻击 / 跳跃」一一对应。
const SHOT_COLOR := Color("d0402f", 0.85)
const HOP_COLOR := Color("7a5cd0", 0.9)
## 格线宽度（像素）。棋盘不画外框，见 _draw_grid()。
const GRID_WIDTH := 1.0
## 棋子字号相对格宽的比例（与 Piece.FONT_RATIO 一致）。
const GLYPH_RATIO := 0.62
## 箭头线宽相对格宽的比例，以及箭头的头长下限。
const ARROW_WIDTH_RATIO := 0.055
const ARROW_HEAD_RATIO := 0.30
const ARROW_HEAD_MIN := 7.0
## 可见性判定的容差：进入可视区一点点就开始播。
const VISIBLE_MARGIN := 24.0
## 棋盘格子的最大边长（像素）。棋盘逐帧缩放，这是它能到的最大尺寸。
const CELL_SIZE := 46.0
## 画布边长上限（像素）。
##
## 画布按**整段演示的最大范围**定死，不逐帧变：画布尺寸决定排版，
## 它一变卡片里的文字就得重排，看起来像在抖。棋盘在画布内部缩放，
## 所以「打完这一炮棋盘变小了」照样看得见，而排版纹丝不动。
const MAX_SIDE := 340.0
## 从一帧的范围过渡到下一帧的范围用多久（秒）。
##
## 有它才有「缩放」的感觉：击杀之后两块棋盘直接跳成一小块会很突兀。
const BOUNDS_TRANSITION := 0.28
## 棋盘下方那行说明要预留的高度（像素）。
##
## guide.gd 会把 status_changed 的文字放进一个 Label，而**预留多少高度由演示说了算**：
## 不留的话，装演示的容器会正好按画布高度把它卡死，说明文字的第二行就被裁掉了。
const STATUS_RESERVE := 38.0
## 心跳 Tween 的时长（秒），见 _restart_tween。
const HEARTBEAT := 3600.0


## 当前正在播的帧列表。
var _frames: Array = []
## 当前这一帧的下标，以及它已经停了多久（秒）。
var _index := 0
var _elapsed := 0.0
## 心跳 Tween：只用来表达「在播 / 已停」。
var _tween: Tween = null
## 范围过渡用的 Tween。
var _bounds_tween: Tween = null

# 演示区域几何（每次重排时重算）
## 整段演示的**舞台**：作者写了 view 就是所有视口尺寸的最大值，否则是所有帧内容的并集。
## 它整段不变，用来定画布尺寸；当前这一帧看哪几格由 _shown_bounds 说了算。
var _canvas_bounds := Rect2i(Vector2i.ZERO, Vector2i(7, 7))
## 当前这一帧的**镜头**（作者写的 view，或按内容自动推出来的包围盒），逐帧变。
## 用 Rect2 而不是 Rect2i：过渡过程中它取小数，「逐格放大」才看得出是连续的缩放。
var _shown_bounds := Rect2(Vector2.ZERO, Vector2(7, 7))
## 由 _shown_bounds 算出的格宽、棋盘左上角与像素尺寸。
var _cell := 0.0
var _origin := Vector2.ZERO
var _side := Vector2.ZERO
## 上一次重绘时的范围与控件尺寸，用来判断「还要不要继续重绘」（见 _layout_changed）。
var _last_drawn_bounds := Rect2()
var _last_drawn_size := Vector2.ZERO
## 因为「布局变了」而请求重绘的次数。测试用它确认过渡期间每一帧都在重绘。
var _redraw_requests := 0

# 取主题字体用的探针：单个静态 Control 就够，不必为每次重排新建节点。
static var _probe: Control = null


func _ready() -> void:
	name = "GuideDemo"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 演示不参与命中测试与滚动：翻页时不会被它吃掉滚轮事件
	clip_contents = true
	resized.connect(_on_resized)
	_update_canvas_size()
	# _ready 跑完后再判断一次可见性：set_frames 可能发生在 _ready 之前，
	# 那时 is_inside_tree() 还是 false，心跳 Tween 根本建不起来。
	call_deferred("_update_playing")


## 载入一段演示（GuideDemos.build 的产物：一堆「帧」）并从头开始播。
## 传空数组时这个控件不会画任何东西（测试用来确认「没剧本就什么都不画」）。
func set_frames(frames: Array) -> void:
	_frames = frames
	# 舞台取整段的最大视口（作者写了 view 时），没写就是原来的自动推导——见 GuideDemos.canvas_of
	_canvas_bounds = GuideDemos.canvas_of(frames)
	_index = 0
	_elapsed = 0.0
	_update_canvas_size()
	_sync_bounds(get_current_frame(), true)
	_restart_tween()
	status_changed.emit(get_status_text())
	queue_redraw()


## 整段演示的画布范围（不随帧变，用来定画布尺寸），供测试与调试查询。
func get_content_bounds() -> Rect2i:
	return _canvas_bounds


## 当前这一帧实际画出来的格子范围（过渡过程中可能带小数），供测试与调试查询。
func get_shown_bounds() -> Rect2:
	return _shown_bounds


## 范围是否正在过渡（供测试确认「缩放是过渡出来的」，不是换帧时跳一下）。
##
## 用 is_valid() 而不是 is_running()：Tween 刚创建的那一帧还没开始跑，
## is_running() 会是 false——查的是「有没有一个活着的过渡」，不是「这一瞬间跑没跑」。
func is_bounds_animating() -> bool:
	return _bounds_tween != null and _bounds_tween.is_valid()


## 当前是否还有待处理的重绘请求。
##
## 过渡期间必须一直有：范围变了却不重绘，画面就会冻在过渡的第一帧，看起来正是一次突变。
## 这是踩过的坑，所以留一个查询口给测试。
##
## 刻意自己数，而不是问引擎「有没有待重绘」——引擎一旦真的重绘过，那个标志就清了，
## 查询结果取决于调用时机，没法稳定断言。这里数的是「我们主动请求过多少次」。
func get_redraw_requests() -> int:
	return _redraw_requests


## 按固定时长手动推进范围过渡，返回推进后的范围。
##
## 只给测试用。测试里 `await process_frame` 一次往往推进好几帧，
## 0.28 秒的过渡在两次采样之间就跑完了，采样结果看起来像突变——
## 那是测量的假象。用它就能一次只推进固定的一小步，确定性地看到中间值。
func advance_bounds_for(seconds: float) -> Rect2:
	if _bounds_tween != null and _bounds_tween.is_valid():
		_bounds_tween.custom_step(seconds)
	return _shown_bounds


## 按整段演示的最大范围定画布大小：画布 = 范围 × 格宽，再加上说明文字那一行。
##
## 这一步很关键——画布必须**同时**给出宽和高。只给高度的话，装它的 CenterContainer
## 会把宽度压成 0，演示整块消失（画布宽 0，格宽自然也是 0）。
func _update_canvas_size() -> void:
	var span := Vector2(_canvas_bounds.size)
	if span.x <= 0.0 or span.y <= 0.0 or _frames.is_empty():
		custom_minimum_size = Vector2.ZERO
		return
	custom_minimum_size = span * _fit_cell(span) + Vector2(0.0, STATUS_RESERVE)


## 把「正在显示的范围」对准这一帧该有的范围。snap 为真时直接到位（载入演示时用）。
##
## 目标范围由 GuideDemos.view_of 给：作者写了 `view` 就是那个矩形（哪怕它比内容小、
## 会把棋子裁到画面外——那是作者的表达），没写才是这一帧内容的包围盒。
## 这一帧空着（view_of 返回空）时什么都不做：镜头停在上一帧，不会跳回整块棋盘。
func _sync_bounds(frame: Dictionary, snap: bool = false) -> void:
	if frame.is_empty():
		return
	var target := GuideDemos.view_of(frame)
	if target.size.x <= 0 or target.size.y <= 0:
		return
	var target_rect := Rect2(Vector2(target.position), Vector2(target.size))
	# 作者要求这一帧硬切：不走 Tween，直接赋值（不然 _process 里的重绘判断会以为在过渡）
	var hard_cut := snap or GuideDemos.view_hold(frame)
	if hard_cut or not is_inside_tree():
		_stop_bounds_tween()
		_shown_bounds = target_rect
		return
	if _shown_bounds == target_rect:
		return
	_stop_bounds_tween()
	# 拖住尾帧的棋子会让范围原地不动，所以这里不需要额外的「没变就别动」判断
	_bounds_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_bounds_tween.tween_property(self, "_shown_bounds", target_rect, BOUNDS_TRANSITION)


func _stop_bounds_tween() -> void:
	if _bounds_tween != null and _bounds_tween.is_valid():
		_bounds_tween.kill()
	_bounds_tween = null


func is_playing() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()


## 跳到某帧（测试与调试用；正常播放走心跳与 _process）。
## 范围直接到位，不做过渡——跳帧是「给测试和调试用的瞬间跳转」。
##
## 这里也发 status_changed：正常播放是 _process 换帧时发的，跳帧若不发，
## 棋盘下方那行字就会停在上一次的说明上（截图、调试时看着像 bug）。
func goto_frame(index: int) -> void:
	if _frames.is_empty():
		return
	_index = clampi(index, 0, _frames.size() - 1)
	_elapsed = 0.0
	_sync_bounds(get_current_frame(), true)
	status_changed.emit(get_status_text())
	queue_redraw()


func get_frame_index() -> int:
	return _index


func get_frame_count() -> int:
	return _frames.size()


func get_current_frame() -> Dictionary:
	return _frames[_index] if _index >= 0 and _index < _frames.size() else {}


## 所有帧的停留时长之和（秒）。测试用它确认时间轴总长不是 0。
func get_total_duration() -> float:
	var total := 0.0
	for frame in _frames:
		total += float(frame.get("hold", 0.0))
	return total


# --- 播放 ---

## 每帧的成本只有一次「在不在可视区里」的判断：不在就立刻返回。
##
## 刻意**不**用 set_process 开关来省这点开销：容器无法可靠地知道自己什么时候被滚进可视区
## （滚动不会触发 visibility_changed，父级重排也不一定触发 resized），
## 依赖那两种通知的结果就是「演示停在第一帧不动」。省下的是极小的开销，
## 代价却是一个查很久才查得出来的 bug。真正的省电手段是下面那点——
## 只有在播的时候才 queue_redraw()。
func _process(delta: float) -> void:
	if _frames.is_empty() or not _is_visible_on_screen():
		return
	if not is_playing():
		_restart_tween()
	# 范围正在过渡（或控件被重排）时，每一帧都得重绘，否则画面会停在过渡的第一帧
	if _layout_changed():
		_redraw_requests += 1
		queue_redraw()
	_elapsed += delta
	var hold := float(_frames[_index].get("hold", 0.0))
	if hold <= 0.0 or _elapsed < hold:
		return
	_elapsed -= hold
	# 末帧停留结束后回到开头：演示是自动循环的，没有停在最后一帧一说
	_index = _index + 1 if _index + 1 < _frames.size() else 0
	# 换帧了：棋盘范围跟着这一帧的内容走（打完这一炮棋盘就收回活着的棋子身上）
	_sync_bounds(get_current_frame())
	status_changed.emit(get_status_text())
	queue_redraw()


## 心跳 Tween：它唯一的作用是让「在播 / 已停」这件事有地方可查（is_playing），
## 时长见文件开头的 HEARTBEAT。帧的推进在 _process 里按每帧自己的 hold 走。
func _restart_tween() -> void:
	if is_playing():
		return
	_stop_tween()
	if not is_inside_tree():
		return
	_tween = create_tween()
	_tween.tween_callback(func() -> void: pass).set_delay(HEARTBEAT)


func _stop_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## 尺寸变了要重绘，也要重新判断「现在能不能播」：
## 首次排版时本控件的高度还是 0，_is_visible_on_screen() 会判成不可见，
## 而那次判断之后不会再有 visibility_changed 通知——必须靠这里补救。
func _on_resized() -> void:
	queue_redraw()
	_update_playing()


func _update_playing() -> void:
	if _is_visible_on_screen():
		_restart_tween()
	else:
		_stop_tween()


## 本演示是否在滚动可视区里。父级是 ScrollContainer，所以拿最近的裁剪矩形来比。
func _is_visible_on_screen() -> bool:
	if not is_visible_in_tree() or size.y <= 0.0:
		return false
	var scroll := _enclosing_scroll()
	if scroll == null:
		return true
	var view := Rect2(scroll.global_position, scroll.size).grow(VISIBLE_MARGIN)
	return view.intersects(Rect2(global_position, size))


## 本演示当前占的矩形（也用于调试与截图定位）。
func get_demo_rect() -> Rect2:
	return Rect2(global_position, size)


func _enclosing_scroll() -> ScrollContainer:
	var node := get_parent()
	while node != null:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null


# --- 几何 ---

## 一格画多大：默认 CELL_SIZE，画布装不下时整体缩小。
##
## 注意棋盘**不是**整块 7×7，而是只画当前这一帧的范围，
## 所以「多少格」要按范围算，不能按真实棋盘边长算。
func _fit_cell(span: Vector2, area: Vector2 = Vector2.ZERO) -> float:
	var cell := CELL_SIZE
	if MAX_SIDE > 0.0:
		cell = minf(cell, MAX_SIDE / maxf(maxf(span.x, span.y), 1.0))
	var room := area if area.x > 0.0 and area.y > 0.0 else Vector2(size)
	if room.x > 0.0 and room.y > 0.0:
		cell = minf(cell, minf(room.x / span.x, room.y / span.y))
	return maxf(cell, 1.0)


func _update_geometry() -> void:
	if _frames.is_empty():
		_cell = 0.0
		return
	# 下半部分留给说明文字，棋盘只占上面那一块
	var canvas := Vector2(size.x, maxf(size.y - STATUS_RESERVE, 1.0))
	_cell = _fit_cell(_shown_bounds.size, canvas)
	_side = _shown_bounds.size * _cell
	# 棋盘在画布里居中：范围小的时候它就在中间缩成一小块
	_origin = (canvas - _side) * 0.5


## 当前的布局（范围 + 控件尺寸）与上一次重绘时相比是否变了。
##
## 判断「要不要继续重绘」只能靠它。别指望范围属性的 setter 会触发 _draw：
## GDScript 里给一个普通成员赋值**不会**自动 queue_redraw()，
## 于是「Tween 在动、画面却停在过渡的第一帧」——看起来就完全像一次突变。
func _layout_changed() -> bool:
	if _last_drawn_bounds != _shown_bounds:
		_last_drawn_bounds = _shown_bounds
		return true
	if _last_drawn_size != size:
		_last_drawn_size = size
		return true
	return false


func _theme_font() -> Font:
	if _probe == null:
		_probe = Control.new()
	# 借用主题字体（和 Label 同一条链路），保证中文在导出后也画得出来。
	return _probe.get_theme_font("font")


# --- 绘制 ---

func _draw() -> void:
	_update_geometry()
	if _cell <= 0.0 or _frames.is_empty():
		return

	var frame := get_current_frame()
	if frame.is_empty():
		return
	var state: Dictionary = frame["state"]

	# 高亮的格子（作者在编辑器里点出来的），画在格线之下
	var highlight: Dictionary = frame.get("highlight", {})
	for cell in highlight.keys():
		draw_rect(_cell_rect(cell), ZONE_COLOR, true)

	_draw_grid()

	for cell in highlight.keys():
		draw_rect(_cell_rect(cell), ZONE_BORDER_COLOR, false, GRID_WIDTH * 2.0)

	_draw_arrows(frame)
	_draw_pieces(state)


## 只画格线，**不画外框**。
##
## 外框会把棋盘圈成一个「方块」，而演示里棋盘是逐帧缩放的：
## 一圈边线跟着放大缩小反而显眼，像在闪烁。棋子与格线已经足够表达棋盘了。
func _draw_grid() -> void:
	var top_left := _origin
	var columns := int(roundf(_shown_bounds.size.x))
	var rows := int(roundf(_shown_bounds.size.y))
	for i in range(1, columns):
		var offset := float(i) * _cell
		draw_line(
			Vector2(top_left.x + offset, top_left.y),
			Vector2(top_left.x + offset, top_left.y + _side.y),
			GRID_COLOR, GRID_WIDTH, true
		)
	for i in range(1, rows):
		var offset := float(i) * _cell
		draw_line(
			Vector2(top_left.x, top_left.y + offset),
			Vector2(top_left.x + _side.x, top_left.y + offset),
			GRID_COLOR, GRID_WIDTH, true
		)


## 箭头按样式上色：移动＝蓝、攻击＝红、跳跃＝紫（和编辑器里选的那三种一致）。
func _draw_arrows(frame: Dictionary) -> void:
	for arrow in frame.get("arrows", []):
		var kind := str(arrow.get("kind", "shot"))
		var color := SHOT_COLOR
		var width := maxf(_cell * ARROW_WIDTH_RATIO, 1.6)
		if kind == "move":
			color = LINE_COLOR
		elif kind == "hop":
			color = HOP_COLOR
		_draw_arrow(_cell_center(arrow["from"]), _cell_center(arrow["to"]), color, width)


## 一条箭头：**两端就落在两个格子的正中心**（不往里缩），这样箭头和棋子、格线是同一套坐标。
##
## 压在棋子字上的那一段不用管：箭头画在棋子**下面**（见 _draw），被盖住的部分本来就看不见，
## 而漏出来的那一段仍然指着目标格的中心。
func _draw_arrow(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var length := from.distance_to(to)
	if length <= 0.001:
		return
	var dir := (to - from) / length
	var head := maxf(_cell * ARROW_HEAD_RATIO, ARROW_HEAD_MIN)
	head = minf(head, length * 0.5)
	var neck := to - dir * head
	draw_line(from, neck, color, width, true)
	var half := head * 0.5
	var normal := Vector2(-dir.y, dir.x) * half
	draw_colored_polygon(PackedVector2Array([to, neck + normal, neck - normal]), color)


## 棋子字画在格子的**正中心**。
##
## 基线不能直接放在格子中心线上：字体给的是「ascent + descent」这条字身框，中文字身框上下并不
## 对称（ascent 远大于 descent），基线压在中心会让整个字明显偏上（46 像素的格子实测偏上 10.5 像素）。
## 把字身框的**中点**对到格子中心（也就是基线落在中心下方 (ascent − descent)/2 处）才对得上。
func _draw_pieces(state: Dictionary) -> void:
	var font := _theme_font()
	var font_size := int(roundf(_cell * GLYPH_RATIO))
	var ascent := font.get_ascent(font_size)
	var descent := font.get_descent(font_size)
	var lift := (ascent - descent) * 0.5
	for cell in state.keys():
		var piece: PieceInfo = state[cell]
		var color: Color = Piece.CAMP_COLORS.get(piece.camp, Color.BLACK)
		var center := _cell_center(cell)
		var glyph_size := font.get_string_size(piece.symbol(), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var baseline := center - Vector2(glyph_size.x * 0.5, 0.0) + Vector2(0.0, lift)
		draw_string(font, baseline, piece.symbol(), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## 棋盘下方那行说明变了就发这个信号。guide.gd 拿它更新一个普通 Label——
## 文字交给 Label 排版（自动换行、不会被裁），演示控件只负责画棋盘。
signal status_changed(text: String)


## 当前这一帧该显示在棋盘下方的说明（现在每帧就一句话）。
func get_status_text() -> String:
	var frame := get_current_frame()
	if frame.is_empty():
		return ""
	return str(frame.get("text", ""))


## 每一格现在画多大（像素）；没在播或没载入帧时为 0。
func get_cell_size() -> float:
	return _cell if not _frames.is_empty() else 0.0


## 棋盘（当前镜头那几格）在控件里占的像素尺寸（宽, 高）。供测试与调试查询。
func get_board_side() -> Vector2:
	return _side


## 棋盘左上角在控件里的位置（像素）。
func get_board_origin() -> Vector2:
	return _origin


# --- 坐标 ---

## 格子坐标 → 本控件内的像素矩形。注意要减掉范围原点：
## 棋盘只画当前范围那几格，(2,1) 完全可能就是画布的左上角那一格。
## 范围在过渡中带小数，所以这里一律用 _shown_bounds.position。
func _cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(_cell_center(cell) - Vector2(_cell, _cell) * 0.5, Vector2(_cell, _cell))


func _cell_center(cell: Vector2i) -> Vector2:
	var local := Vector2(cell) - _shown_bounds.position
	return _origin + (local + Vector2(0.5, 0.5)) * _cell
