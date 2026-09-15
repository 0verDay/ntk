extends Control

## 棋子指南页面（主菜单 →「棋子指南」）。
##
## 左边栏是速查卡（「怎么玩」一张 + 每种棋子一张），点哪一张，右边那一片就显示哪一页。
## **右栏是一整片定死的面板**：大小永远是「返回主菜单下方 → 窗口底部」那一块，
## 不随文字多少伸缩（文字多了在面板内部滚动），所以换来换去也不会看到框子忽大忽小。
## 卡片是按 PieceGuide 现生成的，所以加一种棋子只会多出一张卡，这里不用改。
## 改文案请改 tools/guide_text.py（见 PieceGuide 开头的流水线），或者在编辑器的「文字」页签里改。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## 「怎么玩」那一页的页号。棋子页用它自己的 PieceInfo.Kind，两者不会撞。
const INTRO_PAGE := -1

# --- 左栏卡片的尺寸（宽度由场景里的 Sidebar 定死，这里只管高度与字号）---
## 6 张卡 + 小标题在 720 高的窗口里要放得下（96 到 720-32 共 576 像素），
## 否则左栏会冒出滚动条——见 CARD_MIN_HEIGHT 与场景里 SidebarList 的 separation。
const CARD_MIN_HEIGHT := 80.0
const CARD_GLYPH_SIZE := 32
const CARD_SHORT_SIZE := 13
const CARD_PADDING := 6.0
## 左栏小标题（「五种棋子」）的字号。
const SIDEBAR_HEADING_SIZE := 13

## 「指南文本没读出来」那条提示的字色（红）。
const NOTICE_COLOR := Color(0.725490, 0.192157, 0.145098)

@onready var _list: VBoxContainer = $Margin/Scroll/Padding/List
@onready var _back_button: Button = $BackButton
@onready var _sidebar: PanelContainer = $Sidebar
@onready var _sidebar_list: VBoxContainer = $Sidebar/SidebarMargin/SidebarScroll/SidebarList
@onready var _detail_scroll: ScrollContainer = $Margin/Scroll

## 页号 → 左栏那张卡的按钮。换选中态时要回头改它的样式。
var _card_buttons: Dictionary = {}
## 当前显示的是哪一页：INTRO_PAGE 或某个 PieceInfo.Kind。
var _selected := INTRO_PAGE


func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	# 右栏那一整片：底与边框画在滚动容器自己身上，于是它永远铺满整个右侧区域；
	# 文字只在里面滚动，撑不大也压不扁这片框子。
	_detail_scroll.add_theme_stylebox_override("panel", _make_panel_style())
	_sidebar.add_theme_stylebox_override("panel", _make_sidebar_style())
	_build_sidebar()
	_show_page(_selected)
	_back_button.grab_focus()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# --- 左边栏：速查卡 ---

## 一张「怎么玩」卡 + 小标题 + 每种棋子一张卡。
## 小标题用 PieceGuide.PIECES_TITLE，于是那一节文字在界面上有个着落。
## 卡片由 _make_sidebar_card 自己挂进列表并登记，这里只管按什么顺序叫它。
func _build_sidebar() -> void:
	# 文案没读出来时左栏一张卡都不放：右栏那条提示已经把话说清楚了，
	# 留一排空壳卡片只会让人以为是自己看错了。
	if not PieceGuide.load_problem().is_empty():
		return

	_make_sidebar_card(
		INTRO_PAGE,
		PieceGuide.INTRO_CARD_GLYPH,
		PieceGuide.INTRO_CARD_SHORT,
		PieceGuide.ACCENT_COLOR
	)

	# 一个兵种都没有（文案没导出来）时不留一个孤零零的小标题
	if not PieceGuide.PIECE_NOTES.is_empty():
		_sidebar_list.add_child(_make_sidebar_heading(PieceGuide.PIECES_TITLE))

	for note in PieceGuide.PIECE_NOTES:
		var kind: int = note["kind"]
		_make_sidebar_card(
			kind,
			PieceGuide.symbol_of(kind),
			str(note.get("short", "")),
			Piece.CAMP_COLORS.get(PieceInfo.Camp.RED, Color.BLACK)
		)


## 左栏的一张小标题（比如「五种棋子」）。它只是分组提示，点它没有任何反应。
func _make_sidebar_heading(text: String) -> Label:
	var label := _make_label(text, SIDEBAR_HEADING_SIZE, PieceGuide.ACCENT_COLOR)
	label.name = "SidebarHeading"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.custom_minimum_size = Vector2(0, 26)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


## 左栏的一张速查卡：整个卡片就是一个按钮（大字 + 一句话），点哪儿都算点这张卡。
##
## 卡片内容本身不参与命中测试（mouse_filter 全部 IGNORE），所以压在字上点也命中按钮；
## 选中态由 _style_card 换一套 StyleBox 表示，不靠额外的选中标记。
func _make_sidebar_card(page: int, glyph: String, short: String, glyph_color: Color) -> Button:
	var button := Button.new()
	button.name = "SidebarCard_%s" % (glyph if not glyph.is_empty() else str(page))
	button.custom_minimum_size = Vector2(0.0, CARD_MIN_HEIGHT)
	button.pressed.connect(_on_card_pressed.bind(page))
	# 卡片上的字比按钮长时能看到全文（左栏只有 160 像素宽）
	button.tooltip_text = short

	var fill := MarginContainer.new()
	# 按钮不是容器，子节点得自己铺满它
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.add_theme_constant_override("margin_left", int(CARD_PADDING))
	fill.add_theme_constant_override("margin_right", int(CARD_PADDING))
	fill.add_theme_constant_override("margin_top", int(CARD_PADDING))
	fill.add_theme_constant_override("margin_bottom", int(CARD_PADDING))
	button.add_child(fill)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 2)
	fill.add_child(column)

	var glyph_label := _make_label(glyph, CARD_GLYPH_SIZE, glyph_color)
	glyph_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(glyph_label)

	var short_label := _make_label(short, CARD_SHORT_SIZE, PieceGuide.BODY_COLOR)
	short_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	short_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(short_label)

	_sidebar_list.add_child(button)
	_card_buttons[page] = button
	_style_card(button, false)
	return button


func _on_card_pressed(page: int) -> void:
	if page != _selected:
		_show_page(page)


## 换成某一页：左栏的选中态、右栏的内容一起换。
func _show_page(page: int) -> void:
	_selected = page
	for key in _card_buttons.keys():
		_style_card(_card_buttons[key], key == page)
	_build_detail()
	# 换页要从头看起，不能接着上一页的滚动位置
	_detail_scroll.scroll_vertical = 0


# --- 右边栏：当前这一页 ---

func _build_detail() -> void:
	# 先 remove_child 再 queue_free：queue_free 的旧节点要到本帧末才真的走，
	# 只调它的话新旧两页会并排存在一帧，看着像抖了一下。
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	# 文案读不出来时先把话说清楚：这一页上的字全来自 data/guide_text.json，
	# 读不到就是一片空白，光看页面根本不知道为什么。
	var problem := PieceGuide.load_problem()
	if not problem.is_empty():
		_list.add_child(_make_notice(problem))

	if _selected == INTRO_PAGE:
		_list.add_child(_make_heading(PieceGuide.INTRO_TITLE))
		for point in PieceGuide.INTRO_POINTS:
			_list.add_child(_make_bullet(point))
		# 易错点跟着「怎么玩」走：它是规则的补充，不是另一种棋子的说明
		_list.add_child(_make_heading(PieceGuide.OUTRO_TITLE))
		for point in PieceGuide.OUTRO_POINTS:
			_list.add_child(_make_bullet(point))
		return

	var note := PieceGuide.note_for(_selected)
	if note.is_empty():
		return
	_list.add_child(_make_piece_content(note))


func _make_heading(text: String) -> Label:
	var label := _make_label(text, 28, PieceGuide.ACCENT_COLOR)
	label.custom_minimum_size = Vector2(0, 46)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _make_bullet(text: String) -> Label:
	return _make_label("・%s" % text, 18, PieceGuide.BODY_COLOR)


## 「指南文本没读出来」的提示条：把问题与该跑的命令直接摆在页面上（日志里也有同一段）。
func _make_notice(problem: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "TextProblem"
	card.add_theme_stylebox_override("panel", _make_notice_style())
	card.add_child(_make_label(
		"指南文本没读出来，这一页会缺字（指南上的文字都来自 data/guide_text.json）。\n%s\n"
		% problem
		+ "请在仓库根目录跑一次 python tools/export_guide_text.py，然后重新打开指南。",
		17, NOTICE_COLOR
	))
	return card


## 一枚棋子这一页：上面一行是「棋盘上的那个字 + 说明」，下面是这一段（几段）演示。
##
## 两处刻意这么排：
##
## * 大字只跟**旁边那段文字**成一行，于是它在竖直方向上相对那段文字居中（动画不在这一行里，
##   拉不高这一行，也就不会把大字拽到动画的中间去）；
## * 动画都在正文**下面**，多段时**左右相邻**、整组在面板里居中（骑有两段：连跳 + 夹击）。
##   并排的前提是每段至少有棋盘那么宽——不然标题会被挤成一列竖排的字，见 _make_demo。
func _make_piece_content(note: Dictionary) -> VBoxContainer:
	var kind: int = note["kind"]
	var name := PieceGuide.symbol_of(kind)

	var page := VBoxContainer.new()
	page.name = "Piece_%s" % name
	page.add_theme_constant_override("separation", 16)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(row)

	var glyph := _make_label(name, 46, Piece.CAMP_COLORS.get(PieceInfo.Camp.RED, Color.BLACK))
	glyph.name = "Glyph"
	glyph.custom_minimum_size = Vector2(76, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(glyph)

	var column := VBoxContainer.new()
	column.name = "Text"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	row.add_child(column)

	column.add_child(_make_label("%s：%s" % [name, note["tagline"]], 22, PieceGuide.HEADING_COLOR))
	for point in note["points"]:
		column.add_child(_make_bullet(point))

	# 演示（动态图）排在文字之后：先读说明，再看它动
	var demos := PieceGuide.demos_for(kind)
	if not demos.is_empty():
		var holder := CenterContainer.new()
		holder.name = "Demos"
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_child(holder)
		var strip := HBoxContainer.new()
		strip.name = "Strip"
		strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		strip.add_theme_constant_override("separation", 18)
		holder.add_child(strip)
		for demo in demos:
			strip.add_child(_make_demo(demo))

	return page


## 一段演示：会动的棋盘 + 棋盘下方那句说明。
##
## 定时与逐帧推进都在 GuideDemo 里，这里只负责把棋盘**水平居中**摆好，
## 并把剧本给的 caption 与「正在发生什么」画成普通文字——它们不参与动画，所以用 Label 就好。
func _make_demo(demo: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Demo"
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(center)

	var view := GuideDemo.new()
	center.add_child(view)
	view.set_frames(GuideDemos.build(demo))
	# 整段至少和棋盘一样宽：几段动画并排时（骑有两段），宽度只按内容最窄来算的话，
	# 标题会被挤成一列竖排的字。有了这条下限，标题至少和棋盘一样宽。
	box.custom_minimum_size = Vector2(view.custom_minimum_size.x, 0.0)

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


# --- 样式 ---

## 右栏那一整片面板块的底：浅蓝底 + 细蓝边 + 圆角（和左栏同一套配色）。
## 它画在滚动容器自己身上，所以这一片永远铺满「返回主菜单下方 → 窗口底部」那一块，
## 与这一页有多少字无关。
func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.964706, 0.972549, 0.984314, 1)
	style.set_border_width_all(1)
	style.border_color = Color(0.121569, 0.372549, 0.815686, 0.25)
	style.set_corner_radius_all(10)
	return style


## 「指南文本没读出来」提示条的底：浅红底 + 红边，一眼看出这不是正文。
func _make_notice_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.996078, 0.929412, 0.921569, 1)
	style.set_border_width_all(1)
	style.border_color = Color(0.725490, 0.192157, 0.145098, 0.4)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 14.0
	style.content_margin_bottom = 14.0
	return style


## 左边栏那一整片的底：比白底略深一点，好让它看起来是一条独立的栏。
func _make_sidebar_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.964706, 0.972549, 0.984314, 1)
	style.set_border_width_all(1)
	style.border_color = Color(0.121569, 0.372549, 0.815686, 0.18)
	style.set_corner_radius_all(10)
	return style


## 换一张左栏卡片的样式：选中与否只是换一个主题类型变体
## （MenuCard / MenuCardSelected，定义在 themes/ui_theme.tres，和主菜单同一套配色）。
func _style_card(button: Button, selected: bool) -> void:
	button.theme_type_variation = &"MenuCardSelected" if selected else &"MenuCard"
