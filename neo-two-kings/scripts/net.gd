extends Node

## 网络层：整个游戏唯一的网络出入口。
##
## RPC 要求收发两端有相同路径的节点，所以把入口收敛在这个 autoload（/root/Net）上：
##   - 作为服务端时，把收到的消息交给 GameServer，再把结果发出去；
##   - 作为客户端时，维护本地状态并把服务端消息转发成信号给界面。
##
## 界面只连接这里的信号，不直接接触 MultiplayerAPI。

enum Role { NONE, CLIENT, SERVER }

## WebSocket 已连上服务端
signal client_connected
## 连接服务端失败
signal client_connect_failed(reason: String)
## 与服务端断开
signal client_disconnected(reason: String)
## 收到服务端消息（kind 见 GameServer 里发出的种类）
signal server_message(kind: String, payload: Dictionary)
## 服务端已就绪
signal server_ready(port: int)
## 服务端不认识聊天消息（旧版服务端），联机聊天不可用
signal chat_unsupported

## 连上的服务端最多缓存多少条聊天记录
const CHAT_HISTORY_LIMIT := 200

var role: Role = Role.NONE
var connecting := false

# --- 客户端本地状态 ---
## 我所在的房间号
var room_code := ""
## 我是不是房主
var is_host := false
## 联机对局中我执哪一方
var my_camp: PieceInfo.Camp = PieceInfo.Camp.RED
## 对局是否已经开始
var in_game := false
## 房间里是否已经有对手（房主靠它判断「开始游戏」能否点）。
## 之所以要存成状态而不是只发信号：消息可能在场景切换途中到达，
## 那时新场景还没 _ready、接不到信号，只能靠读这个标志补上。
var opponent_present := false
## 最近一次收到的局面快照
var last_snapshot: Array = []
## 本局收到的聊天记录，元素为 {"camp": int, "text": String}。
## 和 last_snapshot 同样的道理：消息可能在场景切换途中到达，那时新场景还没 _ready、
## 接不到信号，只能先存下来，等对局界面进场时补显示。
var chat_history: Array = []
## 联机聊天是否可用。连上旧版服务端（不认识 chat）后置为 false，
## 这样界面能明确告诉玩家「要更新服务端」，而不是敲了字石沉大海。
var chat_supported := true

var _server: GameServer = null
var _peer: MultiplayerPeer = null


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	# 允许同一个可执行文件按参数以服务端身份启动：
	#   NeoTwoKings.exe --headless -- --server
	# 必须用 `--` 分隔：`--` 之后的参数不会被引擎当作未知参数处理。
	# 这样云服务器上只需要部署一个 exe，不必装 Godot 编辑器。
	if "--server" in OS.get_cmdline_user_args():
		call_deferred("_become_dedicated_server")


## 启动为专用服务端：把主场景换成 headless 服务端场景。
## 用 call_deferred 是因为 autoload 的 _ready 早于主场景装配，直接切会与场景树冲突。
func _become_dedicated_server() -> void:
	if role != Role.NONE:
		return
	print("[服务端] 检测到 --server，切换为专用服务端模式")
	get_tree().change_scene_to_file("res://scenes/server_main.tscn")


# --- 服务端 ---

## 启动 WebSocket 服务端，返回 Error。
func start_server(port: int = NetConfig.SERVER_PORT) -> Error:
	if role != Role.NONE:
		return ERR_ALREADY_IN_USE
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	_server = GameServer.new()
	_server.log_enabled = true
	role = Role.SERVER
	server_ready.emit(port)
	return OK


# --- 客户端 ---

## 连接服务端，返回 Error（连接结果通过信号通知）。
func connect_to_server(url: String = "") -> Error:
	if role != Role.NONE:
		return ERR_ALREADY_IN_USE
	if url.is_empty():
		url = NetConfig.server_url()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	connecting = true
	return OK


## 主动断开并清空本地状态。
func disconnect_from_server() -> void:
	_reset_client()
	if role == Role.SERVER:
		_server = null
	role = Role.NONE
	multiplayer.multiplayer_peer = null
	_peer = null


func create_room() -> void:
	_send_to_server("create_room", {})


func join_room(code: String) -> void:
	_send_to_server("join_room", {"code": code})


func start_game() -> void:
	_send_to_server("start_game", {})


func request_move(from: Vector2i, to: Vector2i) -> void:
	_send_to_server("move", {"from": [from.x, from.y], "to": [to.x, to.y]})


## 发送一条聊天消息。文本先按服务端的同一套规则清洗，空消息不发。
## 自己的消息也等服务端回显（服务端会把消息广播给房间里的双方），
## 这样双方看到的顺序完全一致——与本项目「服务端权威」的一贯做法相同。
func send_chat(text: String) -> void:
	var clean := GameServer.sanitize_chat(text)
	if clean.is_empty():
		return
	_send_to_server("chat", {"text": clean})


func leave_room() -> void:
	if role == Role.CLIENT and not connecting:
		_send_to_server("leave", {})
	_reset_client()


## 是否已经与服务端建立了可用连接（可以安全发 RPC）。
func is_connected_to_server() -> bool:
	if role != Role.CLIENT or _peer == null:
		return false
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _send_to_server(kind: String, payload: Dictionary) -> void:
	# 必须确认真的连上了再发，否则会触发引擎级报错
	# （"Trying to call an RPC via a multiplayer peer which is not connected"）
	if not is_connected_to_server():
		push_warning("尚未连接到服务端，消息 %s 未发送" % kind)
		return
	s_message.rpc_id(1, kind, payload)


# --- RPC ---

## 客户端 → 服务端
@rpc("any_peer", "call_remote", "reliable")
func s_message(kind: String, payload: Dictionary) -> void:
	if role != Role.SERVER or _server == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	_dispatch(_server.handle(sender, kind, payload))


## 服务端 → 客户端
@rpc("authority", "call_remote", "reliable")
func c_message(kind: String, payload: Dictionary) -> void:
	if role != Role.CLIENT:
		return
	_apply_server_message(kind, payload)
	server_message.emit(kind, payload)


func _dispatch(messages: Array) -> void:
	# 必须先确认目标 peer 还在线：对手可能刚好同时掉线，
	# 直接发会让 WebSocket 层抛 "ready_state != STATE_OPEN" 的引擎错误。
	var online := multiplayer.get_peers()
	for message in messages:
		var to: int = message["to"]
		if to <= 0 or not (to in online):
			continue
		c_message.rpc_id(to, message["kind"], message["payload"])


func _apply_server_message(kind: String, payload: Dictionary) -> void:
	match kind:
		"room_created":
			room_code = str(payload.get("code", ""))
			is_host = true
		"joined":
			room_code = str(payload.get("code", ""))
			is_host = false
		"opponent_joined":
			opponent_present = true
		"opponent_left":
			# 对局中途对手离开就整局作废；等待阶段则回到等待界面
			opponent_present = false
			in_game = false
			last_snapshot = []
		"room_closed":
			_reset_client()
		"game_started":
			my_camp = payload.get("camp", PieceInfo.Camp.RED)
			last_snapshot = payload.get("snapshot", [])
			in_game = true
		"state":
			last_snapshot = payload.get("snapshot", [])
		"chat":
			chat_history.append({
				"camp": payload.get("camp", PieceInfo.Camp.RED),
				"text": str(payload.get("text", "")),
			})
			while chat_history.size() > CHAT_HISTORY_LIMIT:
				chat_history.pop_front()
		"error":
			# 旧版服务端的默认分支回的就是「未知消息：<种类>」。据此判定对方不认识 chat，
			# 让界面把聊天输入框锁掉并给出提示。新版服务端不会再发出这条消息。
			# 这是一段一次性的版本兼容垫片，等所有服务端都升级后可以删掉。
			if chat_supported and str(payload.get("reason", "")) == "未知消息：chat":
				chat_supported = false
				chat_unsupported.emit()


# --- 连接事件 ---

func _on_connected_to_server() -> void:
	connecting = false
	client_connected.emit()


func _on_connection_failed() -> void:
	connecting = false
	var reason := "无法连接服务端 %s" % NetConfig.server_url()
	_reset_client()
	multiplayer.multiplayer_peer = null
	_peer = null
	role = Role.NONE
	client_connect_failed.emit(reason)


func _on_server_disconnected() -> void:
	var was_in_game := in_game
	_reset_client()
	multiplayer.multiplayer_peer = null
	_peer = null
	role = Role.NONE
	client_disconnected.emit("房主已离开" if was_in_game else "与服务端的连接已断开")


func _on_peer_connected(peer_id: int) -> void:
	if role == Role.SERVER:
		print("[服务端] 客户端 ", peer_id, " 已连接")


func _on_peer_disconnected(peer_id: int) -> void:
	if role != Role.SERVER or _server == null:
		return
	print("[服务端] 客户端 ", peer_id, " 已断开")
	_dispatch(_server.disconnect_peer(peer_id))


func _reset_client() -> void:
	room_code = ""
	is_host = false
	in_game = false
	opponent_present = false
	last_snapshot = []
	chat_history.clear()
	chat_supported = true
	connecting = false


# --- 调试 ---

func get_server() -> GameServer:
	return _server
