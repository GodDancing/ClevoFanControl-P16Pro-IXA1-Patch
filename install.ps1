#Requires -Version 5.1
<#
.SYNOPSIS
    一键安装：从官方 zip 重建适配版 clevo-fan-control.exe，并铺好厂商 DLL。

.DESCRIPTION
    由同目录的 install.bat 调用（双击即可），也可以直接运行本脚本。

    流程：
      步骤 1/3  空转校验（apply-patch.ps1 -Verify）——不写出产物
      步骤 2/3  正式打补丁 → patch\build\clevo-fan-control.exe
      步骤 3/3  铺设厂商 DLL 副本（setup-dll.ps1）
      收尾      复制示例配置（仅当目标不存在时）
                若以管理员身份运行，可选立即做只读验证（--probe）

    本脚本自身不发任何硬件命令：不动 EC、不转风扇、不改 ACL、不碰注册表。
    唯一会写 EC 的是 clevo-fan-control.exe 本身，而且 --probe 是只读采样。

.PARAMETER Zip
    官方 zip 的完整路径。省略时交互式询问。
    也可以把 zip 文件直接拖到 install.bat 上，路径会自动传进来。

.PARAMETER Yes
    不询问，全部采用默认选择（用于自动化或自测）。

.EXAMPLE
    .\install.bat

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
        -Zip "C:\Users\me\Downloads\ClevoFanControl-v2.0.0-x64.zip"
#>
[CmdletBinding()]
param(
    [string] $Zip,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$patchDir   = Join-Path $root       'patch'
$applyPs1   = Join-Path $patchDir   'apply-patch.ps1'
$dllPs1     = Join-Path $patchDir   'setup-dll.ps1'
$buildDir   = Join-Path $patchDir   'build'
$outExe     = Join-Path $buildDir   'clevo-fan-control.exe'
$exampleCfg = Join-Path $root       'ClevoFanControl.x64.example.json'

$EXPECTED_OUT_SHA256 = '8BC9D40104BABF90BC2AAA0C987424EB7EC5B3A25173A0D8FBC49F837C559A69'

# ---------------------------------------------------------------------------
# 输出helpers
# ---------------------------------------------------------------------------
function Head {
    param([Parameter(Mandatory)][string] $Text)
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Cyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor Cyan
}
function Ok   { param([string]$T) Write-Host "  [OK] $T"   -ForegroundColor Green }
function Bad  { param([string]$T) Write-Host "  [!!] $T"   -ForegroundColor Red }
function Note { param([string]$T) Write-Host "       $T"   -ForegroundColor DarkGray }
function Say  { param([string]$T) Write-Host "  $T" }

function Get-CleanPath {
    param([string] $P)
    if (-not $P) { return '' }
    $p = $P.Trim()
    $p = $p.Trim([char]'"')
    $p = $p.Trim([char]"'")
    return $p.Trim()
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# 开场
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'ClevoFanControl —— 蓝天 P16 Pro IXA1 适配安装' -ForegroundColor White
Write-Host '本安装只做两件事：重建 exe、铺 DLL。全程不发任何硬件命令。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '适用范围提醒：只对机型字符串含 "P16" 的机器有效。' -ForegroundColor Yellow
Write-Host '若不是该机型，请立即按 Ctrl+C 中止。' -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 前置检查：脚本是否齐全
# ---------------------------------------------------------------------------
foreach ($f in @($applyPs1, $dllPs1)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Head '无法开始'
        Bad "缺少脚本：$f"
        Note '请确认 install.bat / install.ps1 与 patch\ 目录在同一层（仓库根目录）。'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 询问 zip 路径 —— 不搜索硬盘，只认你给的路径
# ---------------------------------------------------------------------------
Head '需要官方 zip 的完整路径'

if ($Zip) { $Zip = Get-CleanPath $Zip }

$tries = 0
while (-not ($Zip -and (Test-Path -LiteralPath $Zip -PathType Leaf))) {
    if ($Zip) { Bad "找不到文件：$Zip" }

    if ($Yes) {
        Bad '当前处于 -Yes 模式但没有提供有效的 zip 路径，无法继续。'
        exit 1
    }

    $tries++
    if ($tries -gt 5) {
        Bad '连续 5 次没有拿到有效路径，已退出。'
        exit 1
    }

    Say '请提供 ClevoFanControl-v2.0.0-x64.zip 的完整路径。'
    Note '这一步不搜索硬盘——只认你给出的路径。'
    Note '想不起来放哪了？浏览器按 Ctrl+J 打开下载记录 → 右键 → 在文件夹中显示。'
    Note '也可以把 zip 文件直接拖进这个窗口。输入 q 退出。'
    Write-Host ''
    $answer = Get-CleanPath (Read-Host '  zip 路径')
    if ($answer -eq 'q' -or $answer -eq 'Q') { Write-Host ''; Say '已取消。'; exit 1 }
    $Zip = $answer
}

$Zip = (Resolve-Path -LiteralPath $Zip).Path
Ok "使用 zip：$Zip"

# ---------------------------------------------------------------------------
# 步骤 1/3：空转校验
# ---------------------------------------------------------------------------
Head '步骤 1 / 3  ｜ 空转校验（不写出产物）'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applyPs1 -Zip $Zip -Verify
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Bad '校验未通过，已中止。没有写出产物，也没有改动任何东西。'
    Note '常见原因：zip 不是 v2.0.0 官方原件（哈希不符），或机型不含 "P16"。'
    exit 1
}
Write-Host ''
Ok '校验全过。'

# ---------------------------------------------------------------------------
# 步骤 2/3：正式打补丁
# ---------------------------------------------------------------------------
Head '步骤 2 / 3  ｜ 重建适配版 exe'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applyPs1 -Zip $Zip
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Bad '打补丁失败，已中止。'
    exit 1
}
if (-not (Test-Path -LiteralPath $outExe -PathType Leaf)) {
    Bad "没有找到产物：$outExe"
    exit 1
}

$outHash = (Get-FileHash -LiteralPath $outExe -Algorithm SHA256).Hash
Write-Host ''
Ok "产物：$outExe"
if ($outHash -eq $EXPECTED_OUT_SHA256) {
    Ok "SHA256 $outHash  （与预期一致）"
} else {
    Bad "SHA256 $outHash"
    Bad "与预期 $EXPECTED_OUT_SHA256 不一致 —— 不要使用这个结果。"
    exit 1
}

# ---------------------------------------------------------------------------
# 步骤 3/3：铺厂商 DLL
# ---------------------------------------------------------------------------
Head '步骤 3 / 3  ｜ 铺设厂商 DLL'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dllPs1
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Bad '铺设 DLL 失败。'
    Note 'exe 已经生成，但缺厂商 DLL 时程序无法启动 —— 请按上面的报错处理。'
    exit 1
}

# ---------------------------------------------------------------------------
# 收尾 A：放置示例配置
# ---------------------------------------------------------------------------
$targetCfg = Join-Path $buildDir 'ClevoFanControl.x64.json'
if (Test-Path -LiteralPath $exampleCfg -PathType Leaf) {
    if (Test-Path -LiteralPath $targetCfg -PathType Leaf) {
        Note "已存在配置，未改动：$targetCfg"
    } else {
        Copy-Item -LiteralPath $exampleCfg -Destination $targetCfg -Force
        Ok "已放置配置：$targetCfg"
        Note '（takeOver=false / autoRun=false —— 不接管、不自启，是安全的起点）'
    }
}

# ---------------------------------------------------------------------------
# 收尾 B：只读验证
# ---------------------------------------------------------------------------
Head '可选  ｜ 只读验证 —— 建议现在就做'

$probeCmd = @'
$p = Start-Process -FilePath ".\clevo-fan-control.exe" -ArgumentList "--probe" -Wait -PassThru `
     -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"
"exit=$($p.ExitCode)"; Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"
'@

if (Test-Elevated) {
    $ans = 'y'
    if (-not $Yes) {
        Write-Host ''
        Write-Host '  现在执行只读验证（--probe，只采样、不写 EC）？[Y/n] ' -NoNewline
        $ans = Read-Host
    }
    if ($ans -match '^[nN]') {
        Note '已跳过。想手动做时，在 patch\build 目录里执行：'
        Note $probeCmd
    } else {
        Write-Host ''
        Say '运行 clevo-fan-control.exe --probe ...'
        $o = Join-Path $env:TEMP 'probe.out'
        $e = Join-Path $env:TEMP 'probe.err'
        Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $outExe -ArgumentList '--probe' -WorkingDirectory $buildDir `
                -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        Write-Host ''
        Say "exit code = $($p.ExitCode)"
        foreach ($f in @($o, $e)) {
            if (Test-Path -LiteralPath $f) {
                $c = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
                if ($c -and $c.Trim()) {
                    Write-Host ''
                    Write-Host "--- $f ---" -ForegroundColor DarkGray
                    Write-Host $c.TrimEnd()
                }
            }
        }
        Write-Host ''
        Note '请把上面的风扇数量 / 各通道温度 / 转速，与 Control Center（Fn 热键）逐项核对。'
        Note '若两者不一致 —— 立即停止一切写入操作，说明本适配不适用于本机。'
    }
} else {
    Note '当前进程不是管理员权限，所以没有自动执行只读验证。'
    Note '（程序 manifest 要求 Administrator，非提权状态下无法启动它。）'
    Write-Host ''
    Say '想自动完成这一步：右键 install.bat → 以管理员身份运行，重跑一遍即可。'
    Say '或者手动执行（在 patch\build 目录下）：'
    Note $probeCmd
}

# ---------------------------------------------------------------------------
# 结束
# ---------------------------------------------------------------------------
Head '安装完成'
Ok "程序：$outExe"
Note '配置与 exe 必须同目录，程序才会自动加载。'
Write-Host ''
Write-Host '  接下来（务必按顺序）：' -ForegroundColor Cyan
Write-Host '    1. 以管理员身份运行 clevo-fan-control.exe，打开界面'
Write-Host '    2. 先保持「软件接管」关闭，只观察读数是否随负载正常变化'
Write-Host '    3. 确认无误后再打开「软件接管」，并观察风扇是否按曲线走'
Write-Host ''
Write-Host '  三条最容易误触的：' -ForegroundColor Yellow
Write-Host '    - 不要跑 --hardware-check（它会真的改风扇占空比）'
Write-Host '    - 不要按界面里的「强制冷却」（接管关着它也会写 95%）'
Write-Host '    - 不要用程序内置的默认曲线（45-90 度全是 40% 的平直线）'
Write-Host ''
Write-Host '  回退：' -ForegroundColor Cyan
Write-Host '    - 界面里关闭「软件接管」→ 程序发 0x69 交还固件自动（已实测有效）'
Write-Host '    - 进程被杀、风扇卡住 → Fn 热键打开 Control Center 重设，或重启'
Write-Host '    - 想彻底清干净 → 删除 C:\ProgramData\ClevoFanControl（本方案唯一新增位置）'
Write-Host ''
Write-Host '  接管打开后 EC 会锁存占空比，进程崩溃不会自动交还固件。' -ForegroundColor Yellow
Write-Host '  未验证项清单见 docs\known-risks.md —— 建议读一遍。' -ForegroundColor Yellow
Write-Host ''

exit 0
