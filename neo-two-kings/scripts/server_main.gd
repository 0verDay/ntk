extends Node

## headless 服务端入口。
##
## 启动方式（不需要窗口）：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path <项目目录> res://scenes/server_main.tscn
##
## 服务端只做三件事：监听 WebSocket、维护房间表、用 Session 作为唯一权威算棋。
## 它不创建任何棋子节点，也不加载任何界面。

## 回环自检的超时（毫秒）
const SELF_CHECK_TIMEOUT_MS := 5000

var _probe: WebSocketPeer = null
var _probe_start_ms := 0
var _port := NetConfig.SERVER_PORT


func _ready() -> void:
	var err := Net.start_server(_port)
	if err != OK:
		printerr("[服务端] 启动失败，端口 %d 返回错误码 %d（端口被占用？）" % [_port, err])
		get_tree().quit(1)
		return
	print("[服务端] 已启动，监听 ws://0.0.0.0:%d" % _port)
	print("[服务端] 棋盘 %d x %d，房主执红先手" % [GameServer.BOARD_SIZE, GameServer.BOARD_SIZE])

	# 回环自检：从本机连一次自己。
	# 这一步能抓到一类静默故障——端口被别的程序以更具体的地址占用时，
	# 监听照样成功、客户端却永远握手不上（本机 NahimicService 抢 9080 就是这样）。
	_probe = WebSocketPeer.new()
	_probe_start_ms = Time.get_ticks_msec()
	_probe.connect_to_url("ws://127.0.0.1:%d" % _port)


func _process(_delta: float) -> void:
	if _probe == null:
		return
	_probe.poll()
	match _probe.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			print("[服务端] 回环自检通过：127.0.0.1:%d 可以正常握手" % _port)
			_finish_probe()
		WebSocketPeer.STATE_CLOSED:
			printerr("[服务端] 回环自检失败：127.0.0.1:%d 握手被拒。" % _port)
			printerr("[服务端] 端口很可能被其它程序以 127.0.0.1 的形式占用了，请换一个端口。")
			_finish_probe()
		_:
			if Time.get_ticks_msec() - _probe_start_ms > SELF_CHECK_TIMEOUT_MS:
				printerr("[服务端] 回环自检超时：127.0.0.1:%d 握手一直没完成。" % _port)
				printerr("[服务端] 这通常意味着该端口被别的程序抢占（内核在监听、但对端不说 WebSocket）。")
				_finish_probe()


func _finish_probe() -> void:
	if _probe != null:
		_probe.close()
		_probe = null
	print("[服务端] 按 Ctrl+C 结束")
