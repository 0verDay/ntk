extends Control

## 主界面：开始游戏（本机双人对下）/ 联机游戏 / 退出游戏。

const GAME_SCENE_PATH := "res://scenes/game.tscn"
const ONLINE_SCENE_PATH := "res://scenes/online_menu.tscn"

@onready var _start_button: Button = $CenterContainer/VBoxContainer/StartButton
@onready var _online_button: Button = $CenterContainer/VBoxContainer/OnlineButton
@onready var _quit_button: Button = $CenterContainer/VBoxContainer/QuitButton


func _ready() -> void:
	_start_button.pressed.connect(_on_start_button_pressed)
	_online_button.pressed.connect(_on_online_button_pressed)
	_quit_button.pressed.connect(_on_quit_button_pressed)
	_start_button.grab_focus()


func _on_start_button_pressed() -> void:
	# 本机对局：先清掉可能残留的联机状态，保证进的是单机模式
	Net.disconnect_from_server()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_online_button_pressed() -> void:
	get_tree().change_scene_to_file(ONLINE_SCENE_PATH)


func _on_quit_button_pressed() -> void:
	get_tree().quit()
