extends Control

## 房间大厅：房主在此等待对手并点「开始游戏」，加入者等待房主开始。
## 房主固定执红先手，加入者执绿。

const GAME_SCENE := "res://scenes/game.tscn"
const ONLINE_MENU_SCENE := "res://scenes/online_menu.tscn"

@onready var _code_label: Label = $CenterContainer/VBoxContainer/CodeLabel
@onready var _hint_label: Label = $CenterContainer/VBoxContainer/HintLabel
@onready var _role_label: Label = $CenterContainer/VBoxContainer/RoleLabel
@onready var _start_button: Button = $CenterContainer/VBoxContainer/StartButton
@onready var _leave_button: Button = $CenterContainer/VBoxContainer/LeaveButton


func _ready() -> void:
	Net.client_disconnected.connect(_on_disconnected)
	Net.server_message.connect(_on_server_message)
	_start_button.pressed.connect(_on_start_pressed)
	_leave_button.pressed.connect(_on_leave_pressed)

	_code_label.text = "房间号 %s" % Net.room_code
	if Net.is_host:
		_role_label.text = "你是房主，执红方先手"
		_start_button.visible = true
		_start_button.disabled = true
		_hint_label.text = "等待对手加入…"
		_leave_button.grab_focus()
	else:
		_role_label.text = "你执绿方，后手"
		_start_button.visible = false
		_hint_label.text = "已加入房间，等待房主开始游戏…"
		_leave_button.grab_focus()

	# 消息可能在本场景切换途中就到达（房主刚看到对手加入就点了开始），
	# 那时本场景还没 _ready、接不到信号，所以这里按 Net 里已存下的状态补一次。
	if Net.in_game:
		_hint_label.text = "对局已开始"
		get_tree().call_deferred("change_scene_to_file", GAME_SCENE)
		return
	if Net.is_host and Net.opponent_present:
		_on_opponent_joined()


func _on_opponent_joined() -> void:
	_hint_label.text = "对手已加入，可以开始游戏"
	_start_button.disabled = false
	if Net.is_host:
		_start_button.grab_focus()


func _on_start_pressed() -> void:
	_start_button.disabled = true
	_hint_label.text = "正在开始游戏…"
	Net.start_game()


func _on_leave_pressed() -> void:
	Net.leave_room()
	get_tree().change_scene_to_file(ONLINE_MENU_SCENE)


func _on_disconnected(reason: String) -> void:
	_hint_label.text = reason
	_start_button.disabled = true


func _on_server_message(kind: String, payload: Dictionary) -> void:
	match kind:
		"opponent_joined":
			_on_opponent_joined()
		"opponent_left":
			_hint_label.text = "对手已离开，等待新的对手…"
			_start_button.disabled = true
		"game_started":
			get_tree().change_scene_to_file(GAME_SCENE)
		"room_closed":
			_hint_label.text = str(payload.get("reason", "房间已关闭"))
			_start_button.disabled = true
		"error":
			_hint_label.text = str(payload.get("reason", "操作失败"))
			_start_button.disabled = not (Net.is_host and Net.room_code != "")
