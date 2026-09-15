extends Control

## 主界面：沙盘（本机双人对下）/ 多人（联机游戏）/ 指南 / 设置（暂不可点）/ 退出。
##
## 进场景时标题原地不动，整块按钮面板从下方缓动升起。

const GAME_SCENE_PATH := "res://scenes/game.tscn"
const ONLINE_SCENE_PATH := "res://scenes/online_menu.tscn"
const GUIDE_SCENE_PATH := "res://scenes/guide.tscn"

## 面板从停靠位置下方这么多像素处出发。
const PANEL_RISE_DISTANCE := 120.0
## 升起时长。
const PANEL_RISE_SECONDS := 0.6

@onready var _rise_layer: Control = $RiseLayer
@onready var _start_button: Button = $RiseLayer/Panel/Margin/Columns/StartButton
@onready var _online_button: Button = $RiseLayer/Panel/Margin/Columns/OnlineButton
@onready var _guide_button: Button = $RiseLayer/Panel/Margin/Columns/MiddleColumn/GuideButton
@onready var _quit_button: Button = $RiseLayer/Panel/Margin/Columns/MiddleColumn/QuitButton


func _ready() -> void:
	_start_button.pressed.connect(_on_start_button_pressed)
	_online_button.pressed.connect(_on_online_button_pressed)
	_guide_button.pressed.connect(_on_guide_button_pressed)
	_quit_button.pressed.connect(_on_quit_button_pressed)
	_play_rise_animation()
	_start_button.grab_focus()


## 面板缓动升起：位置从下方 120px 处 ease-out 回到停靠点，同时淡入。
##
## 动的是垫在底下的整屏 Control（RiseLayer），不是面板自己：面板靠 anchors 居中，
## 让外层整体往下挪，它自然跟着走，不用去读「布局算完了没有」的 position，
## 窗口被拉伸时也照样对得上（收尾值就是场景里那组 offsets）。
func _play_rise_animation() -> void:
	_rise_layer.position = Vector2(0.0, PANEL_RISE_DISTANCE)
	_rise_layer.modulate.a = 0.0

	var tween := create_tween().set_parallel(true)
	tween.tween_property(_rise_layer, "position", Vector2.ZERO, PANEL_RISE_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_rise_layer, "modulate:a", 1.0, PANEL_RISE_SECONDS * 0.8) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _on_start_button_pressed() -> void:
	# 本机对局：先清掉可能残留的联机状态，保证进的是单机模式
	Net.disconnect_from_server()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_online_button_pressed() -> void:
	get_tree().change_scene_to_file(ONLINE_SCENE_PATH)


func _on_guide_button_pressed() -> void:
	get_tree().change_scene_to_file(GUIDE_SCENE_PATH)


func _on_quit_button_pressed() -> void:
	get_tree().quit()
