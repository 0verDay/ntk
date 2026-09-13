extends Control

## 联机入口：连接服务端，然后创建房间或加入房间。

const LOBBY_SCENE := "res://scenes/room_lobby.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _status: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var _create_button: Button = $CenterContainer/VBoxContainer/CreateButton
@onready var _join_row: HBoxContainer = $CenterContainer/VBoxContainer/JoinRow
@onready var _code_input: LineEdit = $CenterContainer/VBoxContainer/JoinRow/CodeInput
@onready var _join_button: Button = $CenterContainer/VBoxContainer/JoinRow/JoinButton
@onready var _message: Label = $CenterContainer/VBoxContainer/MessageLabel
@onready var _back_button: Button = $CenterContainer/VBoxContainer/BackButton

var _busy := false


func _ready() -> void:
	Net.client_connected.connect(_on_connected)
	Net.client_connect_failed.connect(_on_connect_failed)
	Net.client_disconnected.connect(_on_disconnected)
	Net.server_message.connect(_on_server_message)

	_create_button.pressed.connect(_on_create_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_code_input.text_changed.connect(_on_code_changed)
	_code_input.text_submitted.connect(func(_text): _on_join_pressed())

	_set_actions_enabled(false)
	_message.text = ""
	if Net.is_connected_to_server():
		_on_connected()
	else:
		_status.text = "正在连接服务器 %s …" % NetConfig.server_url()
		var err := Net.connect_to_server()
		if err != OK:
			_on_connect_failed("无法发起连接（错误码 %d）" % err)


# --- 连接 ---

func _on_connected() -> void:
	_status.text = "已连接服务器，可以创建或加入房间"
	_set_actions_enabled(true)
	_create_button.grab_focus()


func _on_connect_failed(reason: String) -> void:
	_set_actions_enabled(false)
	_status.text = "连接失败"
	_message.text = "%s\n请确认服务端已启动（%s）" % [reason, NetConfig.server_url()]


func _on_disconnected(reason: String) -> void:
	_set_actions_enabled(false)
	_status.text = "已断开"
	_message.text = reason


# --- 创建 / 加入 ---

func _on_create_pressed() -> void:
	_message.text = ""
	_set_busy(true, "正在创建房间…")
	Net.create_room()


func _on_join_pressed() -> void:
	_message.text = ""
	var code := _code_input.text.strip_edges()
	if code.length() != GameServer.CODE_DIGITS or not code.is_valid_int():
		_message.text = "请输入 %d 位数字房间号" % GameServer.CODE_DIGITS
		return
	_set_busy(true, "正在加入房间 %s …" % code)
	Net.join_room(code)


func _on_code_changed(text: String) -> void:
	# 只允许数字
	var digits := ""
	for i in range(text.length()):
		var c := text[i]
		if c >= "0" and c <= "9":
			digits += c
	if digits != text:
		_code_input.text = digits
		_code_input.caret_column = digits.length()


func _on_server_message(kind: String, payload: Dictionary) -> void:
	match kind:
		"room_created", "joined":
			get_tree().change_scene_to_file(LOBBY_SCENE)
		"error":
			_set_busy(false)
			_set_actions_enabled(true)
			_status.text = "已连接服务器，可以创建或加入房间"
			_message.text = str(payload.get("reason", "操作失败"))


# --- 界面状态 ---

func _set_busy(busy: bool, status: String = "") -> void:
	_busy = busy
	_set_actions_enabled(not busy)
	if not status.is_empty():
		_status.text = status


func _set_actions_enabled(enabled: bool) -> void:
	_create_button.disabled = not enabled
	_join_button.disabled = not enabled
	_code_input.editable = enabled


func _on_back_pressed() -> void:
	Net.disconnect_from_server()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
