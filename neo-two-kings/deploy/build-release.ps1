# ============================================================
#  NeoTwoKings 发布版导出
#
#  用法（在任意目录）：
#      powershell -ExecutionPolicy Bypass -File .\deploy\build-release.ps1
#      powershell -ExecutionPolicy Bypass -File .\deploy\build-release.ps1 -Godot "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe"
#      powershell -ExecutionPolicy Bypass -File .\deploy\build-release.ps1 -Android
#
#  产出（都在 exports\ 下）：
#      NeoTwoKings.exe   客户端 + 服务端（同一个 exe，靠 --server 参数区分）
#      NeoTwoKings.apk   安卓客户端（-Android 才导出）
#
#  注意：本文件必须保存为「带 BOM 的 UTF-8」，否则 Windows PowerShell 5.1
#  会按 ANSI 读，把里面的中文读成乱码甚至解析报错。
# ============================================================

param(
    [string]$Godot = '',
    [switch]$Android
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$deployDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj      = Split-Path -Parent $deployDir
$exports   = Join-Path $proj 'exports'
$logFile   = Join-Path $exports 'build.log'
$fail      = 0

function Say($m, $color = 'Gray') { Write-Host $m -ForegroundColor $color }
function Step($n, $title) { Write-Host "`n=== $n. $title ===" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "  [通过] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [失败] $m" -ForegroundColor Red; $script:fail++ }
function Warn($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

# --- 找到 Godot ---
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

New-Item -ItemType Directory -Force -Path $exports | Out-Null

# --- 1. 刷新全局类名缓存 ---
# 这一步不能省：新加的 class_name（比如 PieceGuide）只有在编辑器扫描过之后才会写进
# .godot\global_script_class_cache.cfg，而导出会把这个缓存打进包里。
# 缓存是旧的，导出的客户端一启动就会满屏 "Identifier not declared"。
Step 1 '刷新全局类名缓存（新加的 class_name 必须先被扫描到）'
$out = & $Godot --headless --path $proj --log-file $logFile --import 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Ok '缓存已刷新'
} else {
    Warn "刷新返回退出码 $LASTEXITCODE（通常无害），继续导出。日志：$logFile"
}

# --- 2. 导出 Windows 版 ---
Step 2 '导出 Windows 版（客户端 + 服务端同一个 exe）'
$exe = Join-Path $exports 'NeoTwoKings.exe'
$pck = Join-Path $exports 'NeoTwoKings.pck'
Remove-Item $pck -Force -ErrorAction SilentlyContinue
$before = if (Test-Path $exe) { (Get-Item $exe).LastWriteTime } else { $null }

$out = & $Godot --headless --path $proj --log-file $logFile --export-release 'Windows Desktop' $exe 2>&1 | Out-String
$out | Set-Content -Path (Join-Path $exports 'build-export.log') -Encoding UTF8

if (-not (Test-Path $exe)) {
    Bad "没有生成 $exe，导出失败。完整输出见 exports\build-export.log"
} elseif ($before -and (Get-Item $exe).LastWriteTime -eq $before) {
    Bad "$exe 没有被更新（时间戳没变），导出多半失败了。完整输出见 exports\build-export.log"
} else {
    $mb = [math]::Round((Get-Item $exe).Length / 1MB, 1)
    $stamp = (Get-Item $exe).LastWriteTime
    Ok "$exe 已生成（$mb MB，$stamp）"
}

# 独立 .pck 意味着没有内嵌，部署时必须两个文件一起上传
if (Test-Path $pck) {
    Warn '同时生成了 NeoTwoKings.pck —— 说明 embed_pck 被关掉了。'
    Warn '上传服务器时必须把 .exe 和 .pck 一起传，只传 exe 会起不来（报 pck missing 后秒退）。'
    Warn '想恢复单文件：在 Godot 导出对话框里勾上「嵌入 PCK」，或把 export_presets.cfg 的 binary_format/embed_pck 改回 true。'
} else {
    Ok '没有独立 .pck：项目数据已内嵌，可以单文件部署'
}

# --- 3. 导出安卓版（可选）---
if ($Android) {
    Step 3 '导出安卓版'
    $apk = Join-Path $exports 'NeoTwoKings.apk'
    $apkBefore = if (Test-Path $apk) { (Get-Item $apk).LastWriteTime } else { $null }
    $out = & $Godot --headless --path $proj --log-file $logFile --export-release 'Android' $apk 2>&1 | Out-String
    $out | Set-Content -Path (Join-Path $exports 'build-android.log') -Encoding UTF8

    # 只看「文件在不在」会被上一次的旧 APK 骗过去：导出失败时旧文件仍然躺在那里。
    # 所以必须比时间戳，并检查 Godot 自己打的报错。
    $failed = $out -match 'export for preset .* failed|无法导出'
    if (-not (Test-Path $apk)) {
        Bad "没有生成 $apk。完整输出见 exports\build-android.log"
    } elseif ($failed -or ($apkBefore -and (Get-Item $apk).LastWriteTime -eq $apkBefore)) {
        Bad "$apk 没有被更新，安卓导出失败。完整输出见 exports\build-android.log"
        Warn '最常见原因是没配发布密钥库（日志里会有「找不到发布密钥库，无法导出」）。'
        Warn '请在 Godot 编辑器里：项目 → 导出 → Android → 填好发布密钥库/用户/密码，'
        Warn '再点「导出项目」生成 APK（密钥库密码不适合写进脚本，所以这步没做成命令行）。'
        Warn '注意：exports 里那个旧 APK 是改动之前的版本，没有聊天/指南/长按卡片，不能直接发给玩家。'
    } else {
        $mb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
        $stamp = (Get-Item $apk).LastWriteTime
        Ok "$apk 已生成（$mb MB，$stamp）"
    }
} else {
    Step 3 '安卓版（跳过）'
    Say '  加 -Android 参数可以一并导出 APK。' -ForegroundColor DarkGray
}

# --- 4. 汇总 ---
Step 4 '产物'
Get-ChildItem $exports -Filter 'NeoTwoKings.*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.exe', '.pck', '.apk') } |
    ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
        Write-Host ("  {0,-24} {1,8:N1} MB  {2}  sha256:{3}" -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime, $hash)
    }

Write-Host ""
if ($fail -eq 0) {
    Write-Host '导出完成。下一步（详见 docs\server-deployment.md 第 8 节）：' -ForegroundColor Green
    Write-Host '  1) 把 exports\NeoTwoKings.exe 上传覆盖服务器上的 C:\ntk\NeoTwoKings.exe' -ForegroundColor Gray
    Write-Host '  2) 重启服务：.\nssm.exe restart NeoTwoKingsServer' -ForegroundColor Gray
    Write-Host '  3) 看服务端日志里的「协议：」这一行有没有 chat —— 有才是新版本' -ForegroundColor Gray
    Write-Host '  4) 把同一个 exe（以及 APK）发给玩家，客户端不更新就用不了聊天' -ForegroundColor Gray
} else {
    Write-Host "有 $fail 个失败项，先按上面的 [失败] 处理。" -ForegroundColor Red
}
exit $fail
