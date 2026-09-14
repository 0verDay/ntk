extends Node

## 端到端联机测试：真的连一次本机的 headless 服务端，建房间、发聊天、等服务端回显。
##
## 需要先启动服务端（tests\run-tests.ps1 会自动起停）：
##     godot --headless --path <项目目录> -- --server
##
## 运行客户端：godot --headless --path <项目目录> res://tests/e2e_client.tscn
## 退出码 0 表示全部通过。

## 单条等待的超时（秒）
const WAIT_TIMEOUT := 6.0
## 「服务端应当毫无反应」这类反向断言要等多久才敢下结论（秒）
const QUIET_TIMEOUT := 1.5

var _inbox: Array = []
var _passed := 0
var _failed := 0
## _run() 全程跑完才会置为 true。中途因为脚本错误中断时它仍是 false，
## 这样就不会出现「测试半路挂了、却打印『失败 0 项』并返回 0」这种假通过。
var _completed := false


func _ready() -> void:
	Net.client_connected.connect(func() -> void: _inbox.append({"kind": "connected", "payload": {}}))
	Net.client_connect_failed.connect(
		func(reason: String) -> void: _inbox.append({"kind": "connect_failed", "payload": {"reason": reason}})
	)
	Net.client_disconnected.connect(
		func(reason: String) -> void: _inbox.append({"kind": "disconnected", "payload": {"reason": reason}})
	)
	Net.server_message.connect(
		func(kind: String, payload: Dictionary) -> void:
			_inbox.append({"kind": kind, "payload": payload})
	)

	await _run()
	if not _completed:
		printerr("测试没有跑完就中断了（多半是上面的 SCRIPT ERROR），按失败处理。")
		get_tree().quit(1)
		return
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	var url := "ws://127.0.0.1:%d" % NetConfig.SERVER_PORT
	print("=== 联机端到端测试（%s）===" % url)

	var err := Net.connect_to_server(url)
	if err != OK:
		_check(false, "发起连接（错误码 %d）" % err)
		return

	var connected := await _wait_for("connected")
	if connected.is_empty():
		var failed := _take("connect_failed")
		_check(false, "连上服务端（%s）" % ("超时" if failed.is_empty() else str(failed["payload"]["reason"])))
		return
	_check(true, "连上服务端")

	Net.create_room()
	var created := await _wait_for("room_created")
	if created.is_empty():
		_check(false, "创建房间（超时或失败）")
		return
	_check(true, "创建房间")
	var code := str(created["payload"].get("code", ""))
	_check(code.length() == GameServer.CODE_DIGITS, "拿到 %d 位数字房间号（%s）" % [GameServer.CODE_DIGITS, code])

	# 1) 正常聊天：服务端会把消息同时回显给发送者，所以单个客户端就能验证整条链路
	Net.send_chat("  你好，联机聊天  ")
	var echo := await _wait_for("chat")
	_check(not echo.is_empty(), "服务端把聊天回显给了发送者")
	if echo.is_empty():
		return
	_check(str(echo["payload"].get("text", "")) == "你好，联机聊天", "回显文本正确且已去首尾空白")
	_check(int(echo["payload"].get("camp", -1)) == PieceInfo.Camp.RED, "房主的消息阵营为红")

	# 2) 长度上限：绕过客户端清洗直接发超长文本，考验服务端自己的兜底
	var long_text := ""
	for i in range(GameServer.CHAT_MAX_LENGTH + 80):
		long_text += "字"
	Net._send_to_server("chat", {"text": long_text})
	var trimmed := await _wait_for("chat")
	_check(
		not trimmed.is_empty()
			and str(trimmed["payload"].get("text", "")).length() == GameServer.CHAT_MAX_LENGTH,
		"服务端把超长聊天截断到 %d 字" % GameServer.CHAT_MAX_LENGTH
	)

	# 3) 换行在服务端被压成空格（聊天记录是一行一条，夹换行会冲乱版式）
	Net._send_to_server("chat", {"text": "第一行\n第二行"})
	var wrapped := await _wait_for("chat")
	_check(str(wrapped["payload"].get("text", "")) == "第一行 第二行", "换行在服务端被压成空格")

	# 4) 纯空白：既不广播也不报错（反向断言，等一小会儿确认没有任何回应）
	Net._send_to_server("chat", {"text": "   \n\t  "})
	await get_tree().create_timer(QUIET_TIMEOUT).timeout
	_check(_take("chat").is_empty(), "纯空白消息没有任何回应")
	_check(_take("error").is_empty(), "纯空白消息不会被当成错误")

	# 5) 离开房间后再聊天：服务端应当明确回错，而不是静默丢弃
	Net.leave_room()
	await get_tree().create_timer(0.5).timeout
	Net._send_to_server("chat", {"text": "已经离开了"})
	var rejected := await _wait_for("error")
	_check(
		not rejected.is_empty() and str(rejected["payload"].get("reason", "")).contains("房间"),
		"离开房间后再聊天会被服务端拒绝"
	)
	_completed = true


# --- 工具 ---

## 等一条指定种类的消息；超时返回空字典。
func _wait_for(kind: String, timeout: float = WAIT_TIMEOUT) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var message := _take(kind)
		if not message.is_empty():
			return message
		await get_tree().process_frame
	return {}


## 从收件箱里取走第一条指定种类的消息。
func _take(kind: String) -> Dictionary:
	for i in range(_inbox.size()):
		if _inbox[i]["kind"] == kind:
			var message: Dictionary = _inbox.pop_at(i)
			return message
	return {}


func _check(condition: bool, title: String) -> void:
	if condition:
		_passed += 1
		print("  [通过] %s" % title)
	else:
		_failed += 1
		printerr("  [失败] %s" % title)
