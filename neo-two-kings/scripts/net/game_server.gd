class_name GameServer
extends RefCounted

## 房间与对局的权威逻辑。刻意不碰任何网络 API：
## 输入是 (peer_id, 消息种类, 载荷)，输出是「该发给谁什么消息」的列表。
## 因此可以完全脱离网络做单元测试，也方便以后原样搬到云服务器上。

const BOARD_SIZE := 7

## 房间号位数（纯数字）
const CODE_DIGITS := 6

## 单条聊天消息的最大长度（字符）。客户端输入框也会限制一次，这里是服务端自己的兜底。
const CHAT_MAX_LENGTH := 200

## 这个服务端认得的所有「客户端 → 服务端」消息种类。
##
## 用途是运维判据：服务端启动横幅会把它打出来，所以升级后只要看一眼日志
## 就知道云端跑的是不是新版本（有 chat 才是带聊天的新版）。
## tests/test_game_server.gd 会逐条验证这里列的 kind 真的被 handle() 处理，
## 免得横幅吹牛。
const CLIENT_KINDS: Array[String] = [
	"create_room",
	"join_room",
	"start_game",
	"move",
	"chat",
	"leave",
]

# code -> Room
var _rooms: Dictionary = {}
# peer_id -> code
var _code_by_peer: Dictionary = {}
var _rng := RandomNumberGenerator.new()
# 记录最近一次生成的房间号，便于测试时固定随机源
var _code_counter := 0
# 打开后会把房间生命周期打到控制台（只在真正的服务端打开，单测保持安静）
var log_enabled := false


func _init() -> void:
	_rng.randomize()


# --- 对外入口 ---

## 处理一条来自 peer_id 的消息。
## 返回要发出的消息列表：[{ "to": peer_id, "kind": String, "payload": Dictionary }, ...]
func handle(peer_id: int, kind: String, payload: Dictionary) -> Array:
	match kind:
		"create_room":
			return _create_room(peer_id)
		"join_room":
			return _join_room(peer_id, payload)
		"start_game":
			return _start_game(peer_id)
		"move":
			return _move(peer_id, payload)
		"chat":
			return _chat(peer_id, payload)
		"leave":
			return _leave(peer_id)
		_:
			return [_error(peer_id, "未知消息：%s" % kind)]


## 玩家断开连接。返回需要通知对手的消息。
func disconnect_peer(peer_id: int) -> Array:
	var room := _room_of(peer_id)
	if room == null:
		return []
	if peer_id == room.host_id:
		# 房主离开则房间直接销毁
		_rooms.erase(room.code)
		_code_by_peer.erase(room.host_id)
		if log_enabled:
			print("[服务端] 房间 %s 已销毁（房主离开），当前房间数 %d" % [room.code, _rooms.size()])
		if room.guest_id != 0:
			_code_by_peer.erase(room.guest_id)
			return [_to(room.guest_id, "room_closed", {"reason": "房主已离开"})]
		return []
	# 加入者离开：房间回到等待状态，房主可以等下一个对手
	room.reset_to_waiting()
	_code_by_peer.erase(peer_id)
	if log_enabled:
		print("[服务端] 房间 %s 的对手离开，回到等待状态" % room.code)
	return [_to(room.host_id, "opponent_left", {})]


# --- 只读查询（测试与调试用） ---

func room_count() -> int:
	return _rooms.size()


func has_room(code: String) -> bool:
	return _rooms.has(code)


func get_room(code: String) -> Room:
	return _rooms.get(code)


func room_of(peer_id: int) -> Room:
	return _room_of(peer_id)


func online_peer_count() -> int:
	return _code_by_peer.size()


# --- 消息处理 ---

func _create_room(peer_id: int) -> Array:
	if _code_by_peer.has(peer_id):
		return [_error(peer_id, "你已经在一个房间里了")]
	var code := _generate_code()
	if code == "":
		return [_error(peer_id, "房间号已用尽，请稍后再试")]
	var room := Room.new(code, peer_id)
	_rooms[code] = room
	_code_by_peer[peer_id] = code
	if log_enabled:
		print("[服务端] 房间 %s 已创建（房主 peer %d），当前房间数 %d" % [code, peer_id, _rooms.size()])
	return [_to(peer_id, "room_created", {"code": code})]


func _join_room(peer_id: int, payload: Dictionary) -> Array:
	if _code_by_peer.has(peer_id):
		return [_error(peer_id, "你已经在一个房间里了")]
	var code := str(payload.get("code", "")).strip_edges()
	if code == "":
		return [_error(peer_id, "请输入房间号")]
	if not _rooms.has(code):
		return [_error(peer_id, "房间 %s 不存在" % code)]
	var room: Room = _rooms[code]
	if room.started:
		return [_error(peer_id, "房间 %s 已经开局了" % code)]
	if room.is_full():
		return [_error(peer_id, "房间 %s 已经满了" % code)]
	room.guest_id = peer_id
	_code_by_peer[peer_id] = code
	return [
		_to(peer_id, "joined", {"code": code}),
		_to(room.host_id, "opponent_joined", {"code": code}),
	]


func _start_game(peer_id: int) -> Array:
	var room := _room_of(peer_id)
	if room == null:
		return [_error(peer_id, "你不在任何房间里")]
	if peer_id != room.host_id:
		return [_error(peer_id, "只有房主可以开始游戏")]
	if room.started:
		return [_error(peer_id, "对局已经开始")]
	if not room.is_full():
		return [_error(peer_id, "还没有对手加入")]
	room.session = Session.new(BOARD_SIZE)
	room.session.start()
	room.started = true
	if log_enabled:
		print("[服务端] 房间 %s 开局：红=peer %d，绿=peer %d" % [room.code, room.host_id, room.guest_id])
	var snapshot := room.session.to_snapshot()
	return [
		_to(room.host_id, "game_started", {"camp": PieceInfo.Camp.RED, "snapshot": snapshot}),
		_to(room.guest_id, "game_started", {"camp": PieceInfo.Camp.GREEN, "snapshot": snapshot}),
	]


func _move(peer_id: int, payload: Dictionary) -> Array:
	var room := _room_of(peer_id)
	if room == null:
		return [_error(peer_id, "你不在任何房间里")]
	if not room.started or room.session == null:
		return [_error(peer_id, "对局还没开始")]
	if room.camp_of(peer_id) != room.session.current_camp:
		return [_error(peer_id, "还没轮到你走")]
	var from := _to_cell(payload.get("from", null))
	var to := _to_cell(payload.get("to", null))
	if from.x < 0 or to.x < 0:
		return [_error(peer_id, "坐标格式错误")]
	if not room.session.try_move(from, to):
		return [_error(peer_id, "非法走法")]
	return _broadcast(room, "state", {"snapshot": room.session.to_snapshot()})


func _leave(peer_id: int) -> Array:
	return disconnect_peer(peer_id)


## 房间内的聊天：服务端只做清洗与转发，不保存历史。
##
## 之所以必须经过服务端：客户端之间没有直连（拓扑是「客户端 ↔ 服务端」的星形），
## 只有服务端能替它们转发。转发时把自己也算进收信人，
## 这样双方的显示顺序完全由服务端决定，不会出现两边顺序不一致。
func _chat(peer_id: int, payload: Dictionary) -> Array:
	var room := _room_of(peer_id)
	if room == null:
		return [_error(peer_id, "你不在任何房间里")]
	var text := sanitize_chat(payload.get("text", ""))
	# 空消息（或只有空白）直接丢弃：既不广播也不报错，免得刷屏
	if text.is_empty():
		return []
	return _broadcast(room, "chat", {"text": text, "camp": room.camp_of(peer_id)})


# --- 工具 ---

func _room_of(peer_id: int) -> Room:
	var code = _code_by_peer.get(peer_id)
	if code == null:
		return null
	return _rooms.get(code)


## 生成一个未被占用的房间号。
func _generate_code() -> String:
	var limit := int(pow(10, CODE_DIGITS))
	for attempt in range(2000):
		_code_counter += 1
		var code := "%0*d" % [CODE_DIGITS, _rng.randi_range(0, limit - 1)]
		if not _rooms.has(code):
			return code
	return ""


static func _to_cell(raw) -> Vector2i:
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)


## 清洗一条聊天文本：换行/制表符压成空格、去掉首尾空白、截断到长度上限。
##
## 客户端发送前也会调它，但服务端不能因此就信任输入——这里再兜一次底。
## 换行必须处理掉：聊天记录是一行一条，文本里夹换行会把版式冲乱。
static func sanitize_chat(raw) -> String:
	var text := str(raw).replace("\r", " ").replace("\n", " ").replace("\t", " ").strip_edges()
	if text.length() > CHAT_MAX_LENGTH:
		text = text.substr(0, CHAT_MAX_LENGTH)
	return text


func _to(peer_id: int, kind: String, payload: Dictionary) -> Dictionary:
	return {"to": peer_id, "kind": kind, "payload": payload}


func _error(peer_id: int, reason: String) -> Dictionary:
	return _to(peer_id, "error", {"reason": reason})


## 广播给房间里的双方（对手还没进来时只发给房主）。
func _broadcast(room: Room, kind: String, payload: Dictionary) -> Array:
	var messages := [_to(room.host_id, kind, payload)]
	if room.guest_id != 0:
		messages.append(_to(room.guest_id, kind, payload))
	return messages
