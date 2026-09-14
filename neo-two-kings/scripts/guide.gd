extends Control

## 棋子指南页面（主菜单 →「棋子指南」）。
##
## 文字全部来自 PieceGuide（唯一数据源），本文件只负责排版：
## 段落、条目、每种棋子一张卡片。改文案请改 scripts/piece_guide.gd。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _list: VBoxContainer = $Margin/Scroll/List
@onready var _back_button: Button = $BackButton

var _card_style: StyleBoxFlat


func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_build()
	_back_button.grab_focus()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# --- 生成界面 ---

func _build() -> void:
	_card_style = _make_card_style()

	_list.add_child(_make_heading(PieceGuide.INTRO_TITLE))
	for point in PieceGuide.INTRO_POINTS:
		_list.add_child(_make_bullet(point))

	_list.add_child(_make_heading(PieceGuide.PIECES_TITLE))
	for note in PieceGuide.PIECE_NOTES:
		_list.add_child(_make_piece_card(note))

	_list.add_child(_make_heading(PieceGuide.OUTRO_TITLE))
	for point in PieceGuide.OUTRO_POINTS:
		_list.add_child(_make_bullet(point))


func _make_heading(text: String) -> Label:
	var label := _make_label(text, 28, PieceGuide.ACCENT_COLOR)
	label.custom_minimum_size = Vector2(0, 46)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _make_bullet(text: String) -> Label:
	return _make_label("・%s" % text, 18, PieceGuide.BODY_COLOR)


## 一枚棋子一张卡片：左边是棋盘上的那个字（用红方配色），右边是说明。
func _make_piece_card(note: Dictionary) -> PanelContainer:
	var kind: int = note["kind"]
	var name := PieceGuide.symbol_of(kind)

	var card := PanelContainer.new()
	card.name = "Card_%s" % name
	card.add_theme_stylebox_override("panel", _card_style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	card.add_child(row)

	var glyph := _make_label(name, 46, Piece.CAMP_COLORS.get(PieceInfo.Camp.RED, Color.BLACK))
	glyph.custom_minimum_size = Vector2(76, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(glyph)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	row.add_child(column)

	column.add_child(_make_label("%s：%s" % [name, note["tagline"]], 22, PieceGuide.HEADING_COLOR))
	for point in note["points"]:
		column.add_child(_make_bullet(point))

	# 演示（动态图）排在文字之后：先读说明，再看它动
	for demo in PieceGuide.demos_for(kind):
		row.add_child(_make_demo(demo))

	return card


## 一段演示：会动的棋盘 + 棋盘下方那句说明。
##
## 定时与逐帧推进都在 GuideDemo 里，这里只负责把它摆成正方形，
## 并把剧本给的 caption 画成一行普通文字——它不参与动画，所以用 Label 就好。
func _make_demo(demo: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_FILL

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(center)

	var view := GuideDemo.new()
	center.add_child(view)
	view.set_frames(GuideDemos.build(demo))

	var caption := _make_label(str(demo.get("caption", "")), 16, PieceGuide.ACCENT_COLOR)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(caption)

	# 棋盘下方那行「正在发生什么」由普通 Label 排版：会跟着帧变化，且不会被裁掉。
	# 高度取演示控件预留的同一份常量，两边的账才对得上。
	var status := _make_label(view.get_status_text(), 15, PieceGuide.BODY_COLOR)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.custom_minimum_size = Vector2(0, GuideDemo.STATUS_RESERVE)
	view.status_changed.connect(func(text: String) -> void: status.text = text)
	box.add_child(status)
	return box


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.964706, 0.972549, 0.984314, 1)
	style.set_border_width_all(1)
	style.border_color = Color(0.121569, 0.372549, 0.815686, 0.25)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 14.0
	style.content_margin_bottom = 14.0
	return style
