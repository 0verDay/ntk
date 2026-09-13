# ============================================================
#  NeoTwoKings 服务端部署自检
#
#  用法：把本脚本和 NeoTwoKings.exe 放在同一个目录，在服务器上以管理员身份运行：
#      powershell -ExecutionPolicy Bypass -File .\check-server.ps1
#
#  它会依次检查：文件是否就位 / 端口是否被占用 / 服务端能否真正起来 /
#  端口是否在监听 / 防火墙规则是否放行，并把失败原因直接指出来。
# ============================================================

$port = 27080
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $dir 'NeoTwoKings.exe'
$log  = Join-Path $dir 'logs\check.log'
$fail = 0

function Step($n, $title) { Write-Host "`n=== $n. $title ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [通过] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [失败] $m" -ForegroundColor Red; $script:fail++ }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

Step 1 '文件检查'
if (Test-Path $exe) {
    $mb = [math]::Round((Get-Item $exe).Length / 1MB, 1)
    Ok "找到 $exe（$mb MB）"
} else {
    Bad "找不到 $exe —— 请把 NeoTwoKings.exe 和本脚本放在同一目录"
    exit 1
}
$pck = Join-Path $dir 'NeoTwoKings.pck'
if (Test-Path $pck) {
    Warn '同目录存在 NeoTwoKings.pck —— 说明导出时没有内嵌 PCK。'
    Warn '     部署到服务器时必须把 .exe 和 .pck 两个文件一起上传，缺一个都起不来。'
    Warn '     （在 Godot 导出对话框里勾选「嵌入 PCK」可变成单文件）'
} else {
    Ok '没有独立 .pck，项目数据已内嵌，可以单文件部署'
}

Step 2 '端口占用检查'
$busy = netstat -ano | Select-String ":$port\s" | Select-String 'LISTENING'
if ($busy) {
    Warn "$port 端口当前已有监听者："
    $busy | ForEach-Object { Write-Host "        $_" }
    Warn '如果那不是本服务端，客户端会连不上（内核在监听、但对端不说 WebSocket）。请换端口。'
} else {
    Ok "$port 当前空闲"
}

Step 3 '启动服务端'
Get-Process -Name 'NeoTwoKings' -ErrorAction SilentlyContinue | ForEach-Object {
    Warn "发现已在运行的 NeoTwoKings 进程（PID $($_.Id)），先结束它以免端口冲突"
    $_.Kill(); Start-Sleep -Seconds 2
}
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Remove-Item $log -Force -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $exe -ArgumentList '--headless','--','--server' `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
        -PassThru -NoNewWindow
Write-Host "  已启动，PID = $($proc.Id)，等待 10 秒..."
Start-Sleep -Seconds 10

Step 4 '进程与端口状态'
if ($proc.HasExited) {
    Bad "进程已经退出（退出码 $($proc.ExitCode)）—— 服务端没能持续运行"
} else {
    Ok "进程仍在运行（PID $($proc.Id)）"
}

$listen = netstat -ano | Select-String ":$port\s" | Select-String 'LISTENING'
if ($listen) {
    Ok "$port 正在监听："
    $listen | ForEach-Object { Write-Host "        $_" }
} else {
    Bad "$port 没有在监听"
    Warn '最常见原因：启动时漏了 `--` 分隔符，导致程序以无头客户端空转。'
    Warn '请用 deploy\start-server.cmd 启动，或在 NSSM 里把参数写成： --headless -- --server'
}

Step 5 '启动日志'
if (Test-Path $log) {
    Write-Host (Get-Content $log -Raw -Encoding UTF8)
    $txt = Get-Content $log -Raw -Encoding UTF8
    if ($txt -match '回环自检通过') {
        Ok '回环自检通过 —— 服务端本身工作正常'
    } elseif ($txt -match '回环自检失败|回环自检超时') {
        Bad '回环自检失败 —— 该端口被别的程序以 127.0.0.1 的形式抢占，请换端口'
    }
} else {
    Bad "没有生成日志文件 $log"
}

Step 6 'Windows 防火墙'
$rule = Get-NetFirewallRule -DisplayName 'NeoTwoKings*' -ErrorAction SilentlyContinue
if ($rule) {
    Ok "已存在防火墙规则：$($rule.DisplayName -join ', ')"
} else {
    Warn "没有找到放行规则，若要让外网连入请执行："
    Write-Host "        New-NetFirewallRule -DisplayName `"NeoTwoKings 联机服务端`" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any" -ForegroundColor Gray
}

Step 7 '外部可达性（需要你自己判断）'
Write-Host "  本脚本只能验证服务器内部。要确认公网可达，请在【另一台机器】上执行：" -ForegroundColor Gray
Write-Host "        Test-NetConnection <服务器公网IP> -Port $port" -ForegroundColor Gray
Write-Host "  返回 TcpTestSucceeded : True 才算真的通了。" -ForegroundColor Gray
Write-Host "  若是 False，检查腾讯云安全组入站规则是否放行了 TCP $port。" -ForegroundColor Gray

if (-not $proc.HasExited) {
    Write-Host "`n自检用的服务端进程仍在运行（PID $($proc.Id)），现在结束它。" -ForegroundColor Gray
    $proc.Kill()
    Start-Sleep -Seconds 2
}
Write-Host ""
Write-Host "失败项数量：$fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -eq 0) {
    Write-Host "服务端本身没有问题。接下来：" -ForegroundColor Green
    Write-Host "  1) 用 deploy\start-server.cmd 正式启动，或按文档第 5 节注册为常驻服务" -ForegroundColor Gray
    Write-Host "  2) 从另一台机器执行 Test-NetConnection <公网IP> -Port $port 验证公网可达" -ForegroundColor Gray
} else {
    Write-Host "请按上面的 [失败]/[注意] 逐条处理后再跑一次本脚本。" -ForegroundColor Yellow
}
