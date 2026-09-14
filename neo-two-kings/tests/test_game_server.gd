extends SceneTree

## GameServer 的纯逻辑测试：不碰网络，直接喂消息、看它打算发给谁什么。
##
## 运行：godot --headless --path <项目目录> -s res://tests/test_game_server.gd
## 退出码 0 表示全部通过。

const HOST := 101
const GUEST := 202

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== GameServer 协议测试 ===")
	_test_full_session()
	_test_chat_requires_room()
	_test_chat_sanitize()
	_test_chat_after_opponent_left()
	_test_declared_kinds_are_handled()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# --- 用例 ---

## 启动横幅会把 CLIENT_KINDS 打出来当运维判据（升级后看日志里有没有 chat）。
## 这里逐条确认它们真的被处理，免得横幅吹牛——列表里写了、handle() 里却不认。
func _test_declared_kinds_are_handled() -> void:
	print("-- 启动横幅声明的协议种类 --")
	var server := GameServer.new()
	for kind in GameServer.CLIENT_KINDS:
		var out := server.handle(999, kind, {})
		var unknown := false
		for message in out:
			if message["kind"] == "error" and str(message["payload"].get("reason", "")).begins_with("未知消息"):
				unknown = true
		# 参数不全回 error 是正常的（这里只关心「认不认识这个 kind」），
		# 但不能是「未知消息」。
		_check(not unknown, "CLIENT_KINDS 里的 %s 真的被 handle() 处理" % kind)

func _test_full_session() -> void:
	print("-- 建房 / 加入 / 开局 / 聊天 --")
	var server := GameServer.new()

	var created := server.handle(HOST, "create_room", {})
	_check(created.size() == 1 and created[0]["kind"] == "room_created", "建房返回 room_created")
	var code := str(created[0]["payload"]["code"])
	_check(code.length() == GameServer.CODE_DIGITS, "房间号为 %d 位数字" % GameServer.CODE_DIGITS)

	var joined := server.handle(GUEST, "join_room", {"code": code})
	_check(_kinds(joined) == ["joined", "opponent_joined"], "加入房间会同时通知双方")

	var started := server.handle(HOST, "start_game", {})
	_check(_kinds(started) == ["game_started", "game_started"], "开局通知双方")
	_check(int(started[0]["payload"]["camp"]) == PieceInfo.Camp.RED, "房主执红先手")
	_check(int(started[1]["payload"]["camp"]) == PieceInfo.Camp.GREEN, "加入者执绿")

	# 房主聊天：房间里两个人各收到一条，阵营是红，文本已去首尾空白
	var chat := server.handle(HOST, "chat", {"text": " 你好 "})
	_check(chat.size() == 2, "聊天广播给房间里的双方")
	_check(chat[0]["to"] == HOST and chat[1]["to"] == GUEST, "聊天收信人是房主与加入者")
	_check(chat[0]["kind"] == "chat" and chat[1]["kind"] == "chat", "消息种类为 chat")
	_check(str(chat[0]["payload"]["text"]) == "你好", "聊天文本去掉首尾空白")
	_check(int(chat[0]["payload"]["camp"]) == PieceInfo.Camp.RED, "房主发言阵营为红")

	# 加入者聊天：阵营是绿
	var reply := server.handle(GUEST, "chat", {"text": "收到"})
	_check(reply.size() == 2 and int(reply[0]["payload"]["camp"]) == PieceInfo.Camp.GREEN, "加入者发言阵营为绿")

	# 聊天不应该影响对局状态
	_check(server.get_room(code).session.current_camp == PieceInfo.Camp.RED, "聊天不会改动当前回合")


func _test_chat_requires_room() -> void:
	print("-- 不在房间时聊天 --")
	var server := GameServer.new()
	var out := server.handle(999, "chat", {"text": "有人吗"})
	_check(out.size() == 1 and out[0]["kind"] == "error", "不在房间时聊天返回 error")
	_check(out[0]["to"] == 999, "错误回给发消息的人")


func _test_chat_sanitize() -> void:
	print("-- 聊天文本清洗 --")
	_check(GameServer.sanitize_chat("  你好  ") == "你好", "去掉首尾空白")
	_check(GameServer.sanitize_chat("第一行\n第二行") == "第一行 第二行", "换行压成空格")
	_check(GameServer.sanitize_chat("a\tb") == "a b", "制表符压成空格")
	_check(GameServer.sanitize_chat("   ") == "", "纯空白视为空")
	_check(GameServer.sanitize_chat(123) == "123", "非字符串输入转成字符串")

	var long_text := ""
	for i in range(GameServer.CHAT_MAX_LENGTH + 50):
		long_text += "字"
	_check(
		GameServer.sanitize_chat(long_text).length() == GameServer.CHAT_MAX_LENGTH,
		"超长文本截断到 %d 字" % GameServer.CHAT_MAX_LENGTH
	)

	# 服务端不信任客户端：空消息既不广播也不报错
	var server := GameServer.new()
	var created := server.handle(HOST, "create_room", {})
	server.handle(GUEST, "join_room", {"code": str(created[0]["payload"]["code"])})
	_check(server.handle(HOST, "chat", {"text": "   "}).is_empty(), "空消息不广播也不报错")
	_check(server.handle(HOST, "chat", {}).is_empty(), "缺少 text 字段按空消息处理")

	var raw := server.handle(HOST, "chat", {"text": "a" + "\n" + "b"})
	_check(str(raw[0]["payload"]["text"]) == "a b", "服务端自己也会清洗换行")


func _test_chat_after_opponent_left() -> void:
	print("-- 对手离开后的聊天 --")
	var server := GameServer.new()
	var created := server.handle(HOST, "create_room", {})
	var code := str(created[0]["payload"]["code"])
	server.handle(GUEST, "join_room", {"code": code})
	server.handle(GUEST, "leave", {})
	var chat := server.handle(HOST, "chat", {"text": "还在吗"})
	_check(chat.size() == 1 and chat[0]["to"] == HOST, "对手离开后聊天不会再发给已离开的人")


# --- 工具 ---

func _check(condition: bool, title: String) -> void:
	if condition:
		_passed += 1
		print("  [通过] %s" % title)
	else:
		_failed += 1
		printerr("  [失败] %s" % title)


func _kinds(messages: Array) -> Array:
	var result := []
	for message in messages:
		result.append(message["kind"])
	return result
