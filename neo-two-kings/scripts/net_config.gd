class_name NetConfig
extends RefCounted

## 网络配置。
##
## 目前是硬编码常量：迁移到云服务器时改 SERVER_HOST，然后重新导出客户端。
## 服务端只用到 SERVER_PORT，与 host 无关。

## 服务端地址。
##
## 这里填的是腾讯云服务器的公网 IP。改这个值之后**必须重新导出并分发给所有玩家**。
## 如果在同一台机器上做本地联调，把它临时改回 "127.0.0.1"。
const SERVER_HOST := "159.75.154.122"
## 服务端监听端口。
##
## 刻意避开 9080：不少笔记本预装的 NahimicService（音频增强）会占用 127.0.0.1:9080，
## 而 Windows 会把 127.0.0.1 的连接优先路由到那个更具体的绑定，
## 结果是服务端看起来正常启动、客户端却永远连不上（握手卡在连接中）。
const SERVER_PORT := 27080
## 握手超时（秒）。
const CONNECT_TIMEOUT := 8.0

## 客户端要连的 WebSocket 地址。
static func server_url() -> String:
	return "ws://%s:%d" % [SERVER_HOST, SERVER_PORT]
