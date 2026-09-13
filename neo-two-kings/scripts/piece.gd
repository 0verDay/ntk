class_name Piece
extends Label

## 棋子的视觉表现：只是一个 Label，按 PieceInfo 显示兵种文字与阵营颜色。
##
## 它不持有任何游戏数据——局面由 Board 上的 Dictionary[Vector2i -> PieceInfo] 持有，
## Board 通过 apply_info() 把数据推给这个节点。所以服务端永远不会创建这个节点。
##
## 位置、尺寸与高亮样式由 Board 驱动，不要手动设置 position / size / theme。

## 各阵营的文字颜色。
const CAMP_COLORS: Dictionary = {
	PieceInfo.Camp.RED: Color("cc2f26"),
	PieceInfo.Camp.GREEN: Color("1f9d4d"),
}

## 字号相对格子边长的比例。
const FONT_RATIO := 0.62
## 高亮圆角半径相对格子边长的比例。
const CORNER_RATIO := 0.14
## 高亮相对格子边缘的内缩比例，避免压住棋盘线。
const INSET_RATIO := 0.05
## 死亡渐隐的默认时长（秒），0 表示立即消失。
const DEATH_FADE_DURATION := 0.3

const HOVER_BG := Color(0.121569, 0.372549, 0.815686, 0.1)
const HOVER_BORDER := Color(0.121569, 0.372549, 0.815686, 0.45)
const SELECTED_BG := Color(0.121569, 0.372549, 0.815686, 0.3)
const SELECTED_BORDER := Color(0.121569, 0.372549, 0.815686, 1)
const HOVER_BORDER_WIDTH := 2
const SELECTED_BORDER_WIDTH := 3

## 当前显示的棋子数据。
var info: PieceInfo = null
## 这个节点当前被摆在哪一格。纯视图属性，游戏数据在 Board 的局面字典里。
var cell: Vector2i = Vector2i.ZERO
## 是否正在播放死亡渐隐。这类棋子已不在局面上，只是还在渲染。
var is_dying := false

var _hovered := false
var _selected := false
# 复用样式对象，避免每次重排都新建（窗口拖动缩放时会频繁调用）
var _empty_style := StyleBoxEmpty.new()
var _hover_style := StyleBoxFlat.new()
var _selected_style := StyleBoxFlat.new()


func _init(p_info: PieceInfo = null) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	_hover_style.bg_color = HOVER_BG
	_hover_style.border_color = HOVER_BORDER
	_hover_style.set_border_width_all(HOVER_BORDER_WIDTH)
	_selected_style.bg_color = SELECTED_BG
	_selected_style.border_color = SELECTED_BORDER
	_selected_style.set_border_width_all(SELECTED_BORDER_WIDTH)

	if p_info != null:
		apply_info(p_info)
	_apply_style()


## 按棋子数据刷新显示。同一节点被复用到别的兵种/阵营时也走这里。
func apply_info(p_info: PieceInfo) -> void:
	info = p_info
	text = p_info.symbol()
	add_theme_color_override("font_color", CAMP_COLORS.get(p_info.camp, Color.BLACK))


func kind() -> PieceInfo.Kind:
	return info.kind if info != null else PieceInfo.Kind.PAWN


func camp() -> PieceInfo.Camp:
	return info.camp if info != null else PieceInfo.Camp.RED


## 由 Board 在排版时调用：按格子边长换算字号与高亮圆角。
func set_display_size(cell_px: float) -> void:
	if cell_px <= 0.0:
		return
	add_theme_font_size_override("font_size", int(roundf(cell_px * FONT_RATIO)))
	var radius := int(roundf(cell_px * CORNER_RATIO))
	_hover_style.set_corner_radius_all(radius)
	_selected_style.set_corner_radius_all(radius)
	var inset := -cell_px * INSET_RATIO
	_hover_style.set_expand_margin_all(inset)
	_selected_style.set_expand_margin_all(inset)


func set_hovered(value: bool) -> void:
	if _hovered == value:
		return
	_hovered = value
	_apply_style()


func set_selected(value: bool) -> void:
	if _selected == value:
		return
	_selected = value
	_apply_style()


func is_hovered() -> bool:
	return _hovered


func is_selected() -> bool:
	return _selected


## 当前生效的高亮：选中优先于悬停。
func highlight_state() -> String:
	if _selected:
		return "selected"
	if _hovered:
		return "hover"
	return "none"


## 播放死亡渐隐：先脱掉高亮与交互，再把透明度降到 0 并自我释放。
## duration 为 0 或节点不在场景树中时立即释放。
func play_death(duration: float = DEATH_FADE_DURATION) -> void:
	if is_dying:
		return
	is_dying = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_hovered(false)
	set_selected(false)
	if duration <= 0.0 or not is_inside_tree():
		queue_free()
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "modulate:a", 0.0, duration)
	tween.tween_callback(queue_free)


func _apply_style() -> void:
	if _selected:
		add_theme_stylebox_override("normal", _selected_style)
	elif _hovered:
		add_theme_stylebox_override("normal", _hover_style)
	else:
		add_theme_stylebox_override("normal", _empty_style)


func _to_string() -> String:
	return "Piece(%s)" % [info]
