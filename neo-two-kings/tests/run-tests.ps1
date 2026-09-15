# ============================================================
#  NeoTwoKings 测试总入口
#
#  用法（在任意目录）：
#      powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#      powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1 -Godot "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe"
#
#  步骤：
#      0.   指南一致性 + 编辑器自检（tools/guide_text.py ↔ data/guide_text.json、
#           tools/demos/*.py ↔ data/guide_demos.json；需要 python，没装就跳过）
#      1.   GameServer 纯逻辑协议测试（不需要服务端）
#      1.5  指南演示（动态图）测试（纯逻辑 + 帧数据核对，不需要窗口）
#      2.   游玩界面行为测试（真实窗口，会短暂弹窗两次）
#      3.   联机端到端测试（脚本自己起一个 headless 服务端再连它）
#
#  全部通过时退出码为 0。
#
#  注意：本文件必须保存为「带 BOM 的 UTF-8」。Windows PowerShell 5.1 默认按 ANSI
#  读取 .ps1，没有 BOM 会把里面的中文读成乱码，甚至直接解析报错。
# ============================================================

param(
    [string]$Godot = ''
)

# Godot 在无头模式下会往 stderr 打少量环境相关的 ERROR（例如读不到 Windows 根证书库），
# 那是环境噪音、不影响测试结论。这里刻意不用 Stop，免得它把脚本整个中断；
# 每一步的成败都由退出码和显式检查判定。
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj     = Split-Path -Parent $testsDir
$logsDir  = Join-Path $testsDir '_logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$fail = 0

function Say($m, $color = 'Gray') { Write-Host $m -ForegroundColor $color }
function Step($n, $title) { Write-Host "`n=== $n. $title ===" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "  [通过] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [失败] $m" -ForegroundColor Red; $script:fail++ }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

# --- 找到 Godot 可执行文件 ---
if (-not $Godot) {
    $cmd = Get-Command 'godot' -ErrorAction SilentlyContinue
    if ($cmd) {
        $Godot = $cmd.Source
    } else {
        $found = Get-ChildItem -Path 'C:\D\GodotEngine' -Filter 'Godot_*_console.exe' -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { $Godot = $found.FullName }
    }
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Bad '没找到 Godot 可执行文件。请用 -Godot <exe 路径> 指定（建议用带 _console 的那个）'
    exit 1
}
Say "Godot: $Godot"
Say "项目 : $proj"

# 跑一次 Godot 并返回退出码 + 输出。
# --log-file 指到工作区内：默认位置是 user://（%APPDATA%），在受限环境里写不进去。
# -Windowed 用于界面测试：headless 下引擎不派发模拟鼠标事件，点不出真实命中测试。
function Invoke-Godot([string]$logName, [string[]]$GodotArgs, [switch]$Windowed) {
    $logFile = Join-Path $logsDir $logName
    $base = @('--path', $proj, '--log-file', $logFile)
    if (-not $Windowed) { $base = @('--headless') + $base }
    $all = $base + $GodotArgs
    $output = & $Godot @all 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output; Log = $logFile }
}

function Show-Result($result, $title) {
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '\[通过\]|\[失败\]|^通过 \d+ 项|^===|^--') {
            if ($line -match '\[失败\]') { Write-Host $line -ForegroundColor Red }
            elseif ($line -match '\[通过\]') { Write-Host $line -ForegroundColor Green }
            else { Write-Host $line }
        }
    }
    # 光看退出码不够：脚本解析失败时 Godot 会打一堆 SCRIPT ERROR 然后照样退 0，
    # 测试其实根本没跑。所以必须看到那句汇总才算真的跑过。
    $ran = $result.Output -match '通过 \d+ 项，失败 \d+ 项'
    if ($result.Code -eq 0 -and $ran) {
        Ok $title
    } elseif ($result.Code -eq 0 -and -not $ran) {
        Bad "$title（退出码是 0，但没看到测试汇总——多半是脚本没跑起来。完整日志：$($result.Log)）"
    } else {
        Bad "$title（退出码 $($result.Code)，完整日志：$($result.Log)）"
    }
}

# --- 0. 指南一致性（Python 工具）---
# 指南有两样东西、两条流水线，游戏读的都是导出出来的 JSON：
#   纯文本：tools/guide_text.py → neo-two-kings\data\guide_text.json
#   演示：  tools/demos/*.py    → neo-two-kings\data\guide_demos.json
# 两边不一致 = 改了源头忘了导出，那后面测的其实是旧内容——测试再绿也不代表你改的那版是对的。
# 没装 python 时只提醒不判红：这一步是「防忘记」，不是测试本身。
Step 0 '指南一致性（tools/guide_text.py 与 tools/demos/*.py → data/*.json）'
$python = (Get-Command 'python' -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command 'py' -ErrorAction SilentlyContinue).Source }
if (-not $python) {
    Warn '没找到 python，跳过这一步（游戏那边的测试照常跑，只是不检查「改了源头忘了导出」）'
} else {
    $toolsRoot = Split-Path $proj -Parent
    # 刻意不接管输出：让 Python 直接往控制台写，编码交给控制台自己
    #（Windows PowerShell 5.1 的 cp936 与 pwsh 的 UTF-8 都能正确显示）。
    foreach ($task in @(
        @{ Name = '指南文案'; Script = 'tools\export_guide_text.py';  Hint = 'python tools\export_guide_text.py' },
        @{ Name = '演示剧本'; Script = 'tools\export_guide_demos.py'; Hint = 'python tools\export_guide_demos.py' }
    )) {
        & $python (Join-Path $toolsRoot $task.Script) --check
        if ($LASTEXITCODE -eq 0) {
            Ok "$($task.Name)与 JSON 一致"
        } else {
            Bad "$($task.Name)与 JSON 不一致：跑一次 $($task.Hint) 再重试"
        }
    }

    # 编辑器自检：守住「可视化编辑器不会把指南改坏」（两个页签各查一遍）——磁盘上的文件
    # 必须已经是规范形式，渲染→再载入必须一字不差。它不写磁盘，所以随便跑。
    $editor_check = Join-Path $toolsRoot 'tools\editor\selftest.py'
    & $python $editor_check
    if ($LASTEXITCODE -eq 0) {
        Ok '编辑器自检通过（动画与文字两个页签都不丢信息）'
    } else {
        Bad '编辑器自检没过：先跑 python tools\editor\selftest.py 看是哪一条'
    }
}

# --- 1. 协议逻辑 ---
Step 1 'GameServer 协议测试（纯逻辑，无需服务端）'
Show-Result (Invoke-Godot 'unit.log' @('-s', 'res://tests/test_game_server.gd')) 'GameServer 协议测试'

# --- 1.5 指南演示（动态图）---
# 纯逻辑 + 帧数据核对，不需要鼠标也不需要窗口，所以放 headless 里跑；
# 它拿 rules.gd 去核对指南演示里的每一条弹道与每一次击杀。
Step '1.5' '指南演示测试（纯逻辑，无需窗口）'
Show-Result (Invoke-Godot 'guide_demos.log' @('res://tests/test_guide_demos.tscn')) '指南演示测试'

# --- 2. 界面行为 ---
# 这一步会短暂弹出游戏窗口：headless 下没法做鼠标命中测试，
# 而「按钮被上层控件挡住」恰恰只有真实命中测试才测得出来。
Step 2 '界面行为测试（真实窗口，会短暂弹窗两次）'
Show-Result (Invoke-Godot 'ui.log' @('--resolution', '1280x720', 'res://tests/test_game_ui.tscn') -Windowed) '游玩界面测试'
Show-Result (Invoke-Godot 'menu_ui.log' @('--resolution', '1280x720', 'res://tests/test_menu_ui.tscn') -Windowed) '主菜单 / 棋子指南测试'

# --- 3. 端到端联机 ---
Step 3 '联机端到端测试（自起 headless 服务端）'
$port = 27080
$busy = netstat -ano | Select-String ":$port\s" | Select-String 'LISTENING'
if ($busy) {
    Bad "$port 已被占用，端到端测试无法启动自己的服务端。占用者："
    $busy | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
} else {
    $serverLog = Join-Path $logsDir 'server.log'
    Remove-Item $serverLog -Force -ErrorAction SilentlyContinue
    $server = Start-Process -FilePath $Godot `
        -ArgumentList '--headless', '--path', $proj, '--log-file', $serverLog, '--', '--server' `
        -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logsDir 'server.stdout') `
        -RedirectStandardError (Join-Path $logsDir 'server.stderr')

    # 等服务端的回环自检通过再让客户端连，最多等 15 秒。
    # 日志是 UTF-8，必须显式按 UTF-8 读：Windows PowerShell 默认按 ANSI 解码，中文会匹配不上。
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $serverLog) {
            $text = Get-Content $serverLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($text -match '回环自检通过') { $ready = $true; break }
        }
        if ($server.HasExited) { break }
    }

    if ($ready) {
        Ok 'headless 服务端已启动并通过回环自检'
        Show-Result (Invoke-Godot 'e2e.log' @('res://tests/e2e_client.tscn')) '联机端到端测试'
    } else {
        Bad "服务端没能就绪，端到端测试跳过。服务端日志：$serverLog"
    }

    if (-not $server.HasExited) {
        $server.Kill()
        Start-Sleep -Seconds 1
    }
}

# --- 汇总 ---
Write-Host ""
if ($fail -eq 0) {
    Write-Host '全部测试通过。' -ForegroundColor Green
} else {
    Write-Host "有 $fail 个测试文件未通过。" -ForegroundColor Red
}
exit $fail
