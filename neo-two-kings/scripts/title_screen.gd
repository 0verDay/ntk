extends Control

## 启动界面：大标题 +「————点击进入游戏————」。
##
## 只在游戏启动时露一次脸：点进去之后，对局/指南/联机那边返回主菜单都是直接回
## main_menu.tscn 的，不会再绕回这里，所以「进门」这件事只属于这一个场景。
##
## 点击后的动画：大标题一边上移、一边缩到主菜单的字号，正好落到主菜单标题的位置，
## 提示文字同时淡出；动画放完才切场景。切过去时主菜单的标题就在同一个位置、同一个
## 字号，看着是「标题自己滑上去」，而不是两个界面硬接。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## 呼吸渐隐的下限：不整条消失，留一点底色，观感更稳。
const HINT_MIN_ALPHA := 0.15
## 单程时长（渐隐、渐显各算一程）。
const BREATH_SECONDS := 1.4

## 大标题的落点：必须和 main_menu.tscn 里那个 Title 的 offset 一模一样，
## 否则切场景的一瞬间标题会跳一下。
const TITLE_REST_TOP := 40.0
const TITLE_HEIGHT := 84.0
## 启动界面上大标题的字号，以及它要缩到的「主菜单字号」。
const TITLE_FONT_SIZE := 76
const MENU_TITLE_FONT_SIZE := 56
## 进门动画：标题上移的时长 / 提示文字淡出的时长。
const ENTER_SECONDS := 0.45
const HINT_FADE_SECONDS := 0.3

@onready var _title: Label = $Title
@onready var _hint: Label = $Hint

var _breath: Tween
## 切场景是延迟执行的，这里挡一道：连点两下、点击和回车一起来，都只切一次。
var _entered := false


func _ready() -> void:
	_start_breathing()


## 提示文字的呼吸渐显渐隐：1.0 → 0.15 → 1.0 无限循环。
## 两端都用正弦缓动，免得节奏发死。
func _start_breathing() -> void:
	_breath = create_tween().set_loops()
	_breath.tween_property(_hint, "modulate:a", HINT_MIN_ALPHA, BREATH_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath.tween_property(_hint, "modulate:a", 1.0, BREATH_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 全屏任意位置点一下都能进（背景和文字都设了 mouse_filter = 2，不会拦这个事件）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			_enter_game()


## 键盘也放行：回车 / 小键盘回车 / 空格。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			get_viewport().set_input_as_handled()
			_enter_game()


func _enter_game() -> void:
	if _entered:
		return
	_entered = true

	# 呼吸的 tween 也在写提示文字的 modulate:a，得先停掉，不然两个 tween 抢同一个属性
	if _breath != null and _breath.is_valid():
		_breath.kill()

	var tween := create_tween().set_parallel(true)
	tween.tween_property(_title, "offset_top", TITLE_REST_TOP, ENTER_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_title, "offset_bottom", TITLE_REST_TOP + TITLE_HEIGHT, ENTER_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(_set_title_font_size, float(TITLE_FONT_SIZE), float(MENU_TITLE_FONT_SIZE), ENTER_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_hint, "modulate:a", 0.0, HINT_FADE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.finished.connect(_go_to_menu)


func _set_title_font_size(size: float) -> void:
	_title.add_theme_font_size_override("font_size", int(round(size)))


func _go_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
