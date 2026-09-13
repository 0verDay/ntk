# 联机服务端部署与迁移（腾讯云 Windows）

本文档记录把一个可用的联机服务端部署到腾讯云 Windows 服务器上的完整步骤。

**验证状态说明**：第 2 节（本机跑通）、单文件导出、`--server` 参数、回环自检、
以及「服务端在非回环网卡上同样可达」都已在本机实测通过。
第 4 节的腾讯云控制台操作、第 4.2 的防火墙命令、第 5 节的常驻方案属于标准运维流程，
本机无法执行（涉及云控制台与系统级配置），请按步骤逐条验证。

---

## 0. 一句话结论

同一个 `NeoTwoKings.exe` 靠参数区分身份：不带参数是客户端，带 `--server` 是服务端。
上云只需要放行**一个 TCP 端口**，但要在**腾讯云安全组**和 **Windows 防火墙**两处都放行，漏一处就连不上。

---

## 1. 架构速览

```
   客户端 A ─┐
             ├─ WebSocket (TCP 27080) ─→  服务端（唯一权威）
   客户端 B ─┘
```

- **服务端权威**：唯一的对局真相在服务端。客户端只发送「我要把某子走到某格」，服务端判定合法性、执行结算，再把新局面推给双方。客户端不自己算结算，所以不可能出现两边不一致。
- **服务端不创建任何棋子节点，也不加载任何界面**——它只跑规则逻辑。
- **传输层是 WebSocket（TCP）**，因此**不需要放行任何 UDP 端口**。
- 房间号是 6 位数字，由服务端随机生成；**房主（创建者）固定执红先手**。

---

## 2. 迁移前：先在本机跑通

在项目根目录（导出产物所在处）打开两个终端窗口：

```powershell
# 窗口 1：服务端
.\NeoTwoKings.exe --headless -- --server

# 窗口 2 和窗口 3：两个客户端
.\NeoTwoKings.exe
```

然后：主菜单 →「联机游戏」→ 一端点「创建房间」，把房间号告诉另一端 → 另一端点「加入房间」并输入房间号 → 房主点「开始游戏」。

### 注意 `--` 分隔符（踩过坑）

`--server` **必须写在 `--` 之后**。`--` 之后的参数不会被引擎当成未知参数处理。

漏掉 `--` 时的症状**极具迷惑性**，实测确认如下：

- 进程**照常在跑**（不会退出，也不会报错）
- stdout **只有一行启动横幅**，看起来「什么都没输出」
- **端口完全没有监听**，从外面连必然失败
- 实际上是应用以「无头客户端」身份在静静空转

所以「服务端没输出 + 端口连不通」的第一嫌疑就是漏了 `--`。
为避免手写出错，直接用 `deploy\start-server.cmd` 启动（见第 3.5 节）。

### 服务端正常启动的标志

```
[服务端] 检测到 --server，切换为专用服务端模式
[服务端] 已启动，监听 ws://0.0.0.0:27080
[服务端] 棋盘 7 x 7，房主执红先手
[服务端] 回环自检通过：127.0.0.1:27080 可以正常握手
```

### 如果看到「回环自检失败 / 超时」

服务端启动时会从本机回环连一次自己，专门用来抓一类**完全静默的故障**：

> Windows 会把 `127.0.0.1:端口` 的连接**优先路由到绑定得更具体的那个套接字**。
> 如果别的程序抢先绑定了 `127.0.0.1:27080`，而服务端绑定的是 `0.0.0.0:27080`，
> 那么客户端连 `127.0.0.1` 时会被那个程序接走——它接受 TCP，但不会说 WebSocket，
> 于是握手永远不完成。**此时服务端看起来一切正常（端口在监听、日志无错），只有客户端连不上。**

这不是假想：本项目最初用的 9080 端口就撞上了笔记本预装的 `NahimicService`（音频增强），
排查了很久才定位。所以现在默认端口改成 27080，并且加了这道自检。

遇到这个提示，**换一个端口**即可：改 `scripts/net_config.gd` 里的 `SERVER_PORT`，重新导出。

### 日志的坑

`NeoTwoKings.exe` 是 Windows **GUI 子系统**程序，直接在终端里运行**看不到任何输出**。
要看日志必须重定向（`2>&1` 不能省，自检失败信息走的是 stderr）：

```powershell
.\NeoTwoKings.exe --headless -- --server *> server.log
```

---

## 3. 云服务器准备

| 项目 | 建议 |
|---|---|
| 配置 | 1 核 2G 足够。回合制、无实时物理、单局状态只有 7x7 棋盘，服务端 CPU 占用极低 |
| 系统 | Windows Server 2019 或更高 |
| 安装目录 | `C:\ntk\` |
| 需要上传的文件 | `NeoTwoKings.exe`（**若 `exports\` 里还有 `.pck`，必须两个一起传**，见下方警告） |
| 是否需要装 Godot | **不需要** |

> ### ⚠ 关于「单文件」的重要警告
>
> 单文件导出依赖 `export_presets.cfg` 里的 `binary_format/embed_pck=true`。
> **如果 Godot 编辑器正好开着这个项目，它可能把这个值改回 `false`**（本项目开发时就遇到过），
> 此时导出会额外产生 `NeoTwoKings.pck`。
>
> 判断方法：打开 `exports\` 看有没有 `.pck` 文件。
> - 只有 `NeoTwoKings.exe` → 已内嵌，单文件部署
> - 有 `NeoTwoKings.exe` + `NeoTwoKings.pck` → **两个都要传**，只传 exe 会在服务器上报
>   `Couldn't load project data ... Is the .pck file missing?` 然后**进程瞬间退出、日志为空**
>
> 在编辑器的「项目 → 导出」对话框里勾选「嵌入 PCK」可以稳定下来。
> `deploy\check-server.ps1` 的第 1 步也会检查这一点。

> 单文件导出是在 `export_presets.cfg` 里把 `binary_format/embed_pck` 设为 `true` 得到的。
> 若改回 `false`，则必须同时上传 `NeoTwoKings.exe` 和 `NeoTwoKings.pck`，缺一不可。

### 3.5 用现成的部署脚本（推荐）

项目 `deploy\` 目录下有两个脚本，与 `NeoTwoKings.exe` 放在同一目录即可用：

| 脚本 | 用途 |
|---|---|
| `start-server.cmd` | **启动服务端**。参数已写死为 `--headless -- --server`，日志自动写入 `logs\server.log`，彻底避免手写参数出错 |
| `check-server.ps1` | **部署自检**。依次检查文件是否就位、端口是否被占用、服务端能否真正起来、端口是否在监听、日志内容、防火墙规则，并把失败原因直接指出来 |

服务端自检的用法（在服务器上以管理员身份运行）：

```powershell
powershell -ExecutionPolicy Bypass -File .\check-server.ps1
```

它会给出「失败项数量」，为 0 就说明服务端本身没问题，剩下的只是防火墙/安全组。

---

## 4. 放行端口（两步都要做）

### 4.1 腾讯云安全组

控制台 → 云服务器 → 安全组 → **入站规则** → 添加规则：

- 类型：自定义
- 协议端口：**TCP:27080**
- 来源：`0.0.0.0/0`（若只想让自己和朋友连，改成你们的固定 IP 更安全）
- 策略：允许

**只需要 TCP。** WebSocket 跑在 TCP 上，不需要放行任何 UDP 端口
（如果将来把传输层换成 ENet，才需要额外放行 UDP）。

### 4.2 Windows 防火墙

在服务器上以管理员身份执行：

```powershell
New-NetFirewallRule -DisplayName "NeoTwoKings 联机服务端" `
  -Direction Inbound -Protocol TCP -LocalPort 27080 -Action Allow -Profile Any
```

### 4.3 验证（必须从另一台机器做）

在**你自己的电脑**上执行，不要在服务器上做（服务器上连自己是回环，绕过了防火墙和公网）：

```powershell
Test-NetConnection <服务器公网IP> -Port 27080
```

看到 `TcpTestSucceeded : True` 才算通。

> ### ⚠ `TcpTestSucceeded : True` 还不等于「服务端可用」
>
> 这个命令只证明**那个端口上有个东西接受了 TCP 连接**，并不证明那个东西**会说 WebSocket**。
> 本项目在开发机上就撞到过：端口被一个音频服务以 `127.0.0.1` 形式抢占后，
> 原始 TCP 连接照样成功，但握手永远完不成，客户端永远连不上。
>
> 真正的判据是**完成一次 WebSocket 握手并跑通一次业务往返**——直接开客户端试即可：
> 能进「联机游戏」、能创建房间拿到房间号，就说明整条链路是好的。

如果是 `False`，按顺序检查：

1. 服务端进程是否真的在跑（服务器上 `netstat -ano | findstr 27080` 应能看到 `LISTENING`）
2. Windows 防火墙规则是否生效（`Get-NetFirewallRule -DisplayName "NeoTwoKings*"`）
3. 腾讯云安全组入站规则是否保存并绑定到了这台实例

---

## 5. 让服务端常驻运行

### 方案 A：任务计划程序（系统自带，无需额外软件）

在服务器上以管理员身份执行：

```powershell
$action  = New-ScheduledTaskAction -Execute "C:\ntk\NeoTwoKings.exe" -Argument "--headless -- --server"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "NeoTwoKingsServer" -Action $action -Trigger $trigger `
  -Settings $settings -User "SYSTEM" -RunLevel Highest -Force

Start-ScheduledTask -TaskName "NeoTwoKingsServer"
```

> 这个方案不收集日志。要看日志用方案 B，或者临时手动前台运行一次。

### 方案 B：NSSM（推荐：自动重启 + 日志转存）

先下载 NSSM（<https://nssm.cc/>）解压到 `C:\ntk\nssm\`，然后：

```powershell
cd C:\ntk\nssm\win64
.\nssm.exe install NeoTwoKingsServer "C:\ntk\NeoTwoKings.exe" --headless -- --server
.\nssm.exe set NeoTwoKingsServer AppStdout C:\ntk\logs\server.log
.\nssm.exe set NeoTwoKingsServer AppStderr C:\ntk\logs\server.err.log
.\nssm.exe set NeoTwoKingsServer AppRotateFiles 1
.\nssm.exe set NeoTwoKingsServer AppExit Default Restart
.\nssm.exe start NeoTwoKingsServer
```

常用操作：

```powershell
.\nssm.exe status  NeoTwoKingsServer
.\nssm.exe restart NeoTwoKingsServer
.\nssm.exe stop    NeoTwoKingsServer
Get-Content C:\ntk\logs\server.log -Tail 30 -Wait
```

> **为什么用 SYSTEM 账户 / NSSM**：服务端必须带 `--headless` 运行。
> 如果以需要交互桌面的账户启动、又没有 `--headless`，它会尝试创建窗口，在无人登录的服务器上会失败。

---

### 5.5 排障：`nssm start` 报 `SERVICE_PAUSED`

```
NeoTwoKingsServer: Unexpected status SERVICE_PAUSED in response to START control.
```

**这是 NSSM 的节流保护，不是启动失败本身。** NSSM 规定：如果应用启动后
在 `AppThrottle`（默认 1500 毫秒）内就退出，它会**暂停服务**，以免陷入疯狂重启。
所以这句话的真正含义是：**服务端进程一起来就死了。**

本项目最常见的原因是**端口已被占用**：

1. 之前手动启动的服务端实例还在跑，占着 27080
2. NSSM 拉起的这个实例绑定端口失败
3. `server_main.gd` 打印错误后立即 `quit(1)`
4. NSSM 看到秒退 → 暂停服务

**处理步骤：**

```powershell
# 1) 看服务端到底报了什么（失败信息走 stderr，所以看 .err.log）
Get-Content C:\ntk\logs\server.err.log -Tail 20
#    预期能看到：[服务端] 启动失败，端口 27080 返回错误码 30（端口被占用？）

# 2) 结束所有残留的服务端进程（包括之前手动启动的那个）
Get-Process NeoTwoKings -ErrorAction SilentlyContinue | Select-Object Id, StartTime
Stop-Process -Name NeoTwoKings -Force

# 3) 确认端口真的空出来了（应当没有任何 LISTENING）
netstat -ano | findstr 27080

# 4) 再启动服务
.\nssm.exe start NeoTwoKingsServer
.\nssm.exe status NeoTwoKingsServer      # 期望 SERVICE_RUNNING
netstat -ano | findstr 27080            # 期望重新出现 LISTENING
```

> **别忘了：手动跑过一次之后，那个窗口还开着就等于占着端口。**
> 正式注册服务之前先把它关掉。

如果 `server.err.log` 里是 `Couldn't load project data ... Is the .pck file missing?`，
那是另一回事——说明 exe 没有内嵌 PCK 而 `.pck` 没一起传上去，见第 3 节的警告。

## 6. 让客户端连到云服务器

编辑 `scripts/net_config.gd`：

```gdscript
const SERVER_HOST := "159.75.154.122"   # 已填入本项目的腾讯云公网 IP
const SERVER_PORT := 27080
```

> **当前仓库里这个值已经是 `159.75.154.122`**，并且 `exports/NeoTwoKings.exe` 也按这个地址导出好了。
> 也就是说：**服务器一上线，这个 exe 就能直接连**，不需要再改代码。
> 只有在同一台机器上做本地联调时，才需要临时改回 `"127.0.0.1"` 并重新导出。

然后在 Godot 里重新导出（或命令行）：

```powershell
Godot_v4.7.2-stable_win64_console.exe --headless --path <项目目录> `
  --export-release "Windows Desktop" <项目目录>\exports\NeoTwoKings.exe
```

把新的 `NeoTwoKings.exe` 分发给玩家。

> **这里是硬编码常量，改完必须重新导出并让所有玩家换新客户端。**
> 如果希望以后改地址不用重新分发客户端，可以改成读 exe 同目录的配置文件、
> 或者在「加入房间」界面上加一个服务器地址输入框。需要的话可以再加。

### 用域名代替 IP

如果有域名，建议解析到公网 IP 后填域名。这样换服务器时只需改 DNS，不用重新分发客户端。
注意 WebSocket 的地址目前写死 `ws://`（明文）。要上 `wss://`（TLS）需要在服务端前面加一层反向代理（如 Caddy / Nginx），
并同时改 `NetConfig.server_url()` 里的 scheme。当前版本未做 TLS。

---

## 7. 部署验证清单

按顺序打勾，跳过任何一步都可能白忙：

- [ ] 服务器上手动前台运行一次，日志出现「**回环自检通过**」
- [ ] `netstat -ano | findstr 27080` 能看到 `0.0.0.0:27080 ... LISTENING`
- [ ] 从**另一台机器** `Test-NetConnection <公网IP> -Port 27080` 返回 `True`
- [ ] 服务已注册为常驻（任务计划程序或 NSSM），且重启服务器后能自动起来
- [ ] 改好 `SERVER_HOST` 并重新导出、分发客户端
- [ ] 两台不同网络的机器各开一个客户端：一端创建房间、一端用房间号加入
- [ ] 房主点「开始游戏」后双方都进入对局，**红方（房主）先手**
- [ ] 各走一步，双方画面一致

---

## 8. 更新服务端

```powershell
# 复制新的 NeoTwoKings.exe 覆盖 C:\ntk\NeoTwoKings.exe
.\nssm.exe restart NeoTwoKingsServer
```

> **更新会中断所有进行中的对局。** 房间表和对局状态全部存在内存里，没有任何持久化，
> 服务端进程一停，所有房间立即消失。

---

## 9. 已知限制（当前版本有意未做）

| 限制 | 说明 |
|---|---|
| **无断线重连** | 任何一方掉线，这一局就结束了（对方会看到「对手已离开对局」） |
| **无观战、无房间列表** | 只能靠 6 位房间号邀请，且房间号只在服务端内存里 |
| **无鉴权、无限流** | 任何人都能连接、建房。**公网暴露时建议在安全组里把来源限制为自己和朋友的 IP** |
| **房间表不持久化** | 服务端重启即清空 |
| **无胜负判定** | 一方棋子被吃光后该方无子可动，回合会卡住（这是早期就存在的设计缺口，尚未补） |
| **无 TLS** | 流量是明文的 `ws://` |
| **硬编码服务器地址** | 换地址要重新导出客户端 |

---

## 10. 协议速查（排障用）

客户端与服务端之间只有两种 RPC，载荷都是「消息种类 + 字典」：

| 方向 | 方法 | kind | 载荷 |
|---|---|---|---|
| 客户端 → 服务端 | `s_message` | `create_room` | `{}` |
| | | `join_room` | `{code}` |
| | | `start_game` | `{}` |
| | | `move` | `{from:[x,y], to:[x,y]}` |
| | | `leave` | `{}` |
| 服务端 → 客户端 | `c_message` | `room_created` | `{code}` |
| | | `joined` | `{code}` |
| | | `opponent_joined` | `{code}` |
| | | `opponent_left` | `{}` |
| | | `room_closed` | `{reason}` |
| | | `game_started` | `{camp, snapshot}` |
| | | `state` | `{snapshot}` |
| | | `error` | `{reason}` |

**快照格式**：`[棋盘边长, 当前回合, [[x, y, 兵种, 阵营], ...]]`
其中兵种 `0=王 1=弓 2=骑 3=盾 4=步`，阵营 `0=红 1=绿`。

服务端日志里能看到房间生命周期，排障时先看这几行：

```
[服务端] 房间 405640 已创建（房主 peer 1234567890），当前房间数 1
[服务端] 房间 405640 开局：红=peer 1234567890，绿=peer 0987654321
[服务端] 房间 405640 已销毁（房主离开），当前房间数 0
```
