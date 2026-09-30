#Requires -Version 5.1
<#
.SYNOPSIS
    从上游官方 release 重建 P16 Pro IXA1 适配版 clevo-fan-control.exe。

.DESCRIPTION
    本脚本只做字节补丁，不重新编译。它对 ClevoFanControl v2.0.0 官方 zip 施加 3 处
    按偏移的就地覆盖，并逐级校验；任何一步不符就中止，不会产出一个"看起来对"的 exe。

    校验链（顺序执行，任一失败即中止）：
      1. 机型：SMBIOS 型号必须含 "P16"
      2. zip 的 SHA256 必须等于官方 digest
      3. zip 内 exe 的 SHA256 必须等于官方 release 的 exe
      4. 三个偏移处的原始字节必须逐字节相符
      5. 补丁 C 的运行时拼接结果必须等于目标路径
      6. 产物 SHA256 必须等于已知的已适配 exe

    第 6 条是关键：它把"补丁逻辑对不对"变成一个可判定的字节级等式。
    第 4 条必须校验完整的字面量，不能只比"变化的字节"——补丁 C 的两条路径
    意外共享了 C:\Program、Control 和 .dll，51 字节里只有 29 字节不同，
    只比变化区间等于自废校验。

    补丁只覆盖 .rdata 里的字面量，所以 .text / .pdata / .rsrc / .reloc 全程未动、
    文件大小不变（2,491,392 字节），PE 结构完好。

.PARAMETER Zip
    官方 zip 的路径。默认先找脚本同目录，再找 Downloads。

.PARAMETER OutDir
    产物目录，默认脚本同目录下的 build\。

.PARAMETER Verify
    只校验，不写文件。用于确认某个 zip 能不能被本脚本正确处理。

.PARAMETER Force
    跳过机型检查。仅在确认是同一机型、但 SMBIOS 字符串不同时才用。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-patch.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-patch.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string] $Zip,
    [string] $OutDir,
    [switch] $Verify,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = Join-Path $scriptDir 'build' }

# ---------------------------------------------------------------------------
# 已知常量。改动其中任何一个都意味着这份适配已经变了，请同步更新 PATCH-NOTES.md。
# ---------------------------------------------------------------------------
$EXPECTED_ZIP_SHA256     = 'A0032BBFDC2AA85EC24CD6C449EC386A548B1B00648511AE18C43345912CB1AC'
$EXPECTED_SRC_SHA256     = '9DB6D1E39EED0F7B1DF765856235FEF58F6F758D63A4BD2AA9B26A8CE07BCE71'
$EXPECTED_OUT_SHA256     = '8BC9D40104BABF90BC2AAA0C987424EB7EC5B3A25173A0D8FBC49F837C559A69'
$EXPECTED_OUT_LENGTH     = 2491392
$EXPECTED_DLL_SHA256     = '75A47020D3A9D052E94DCB4E3AD61FB69F20177DD46E20C9A20883D92B83981B'
$EXPECTED_MODEL_FRAGMENT = 'P16'
$DLL_TARGET_PATH         = 'C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll'
$UPSTREAM_URL            = 'https://github.com/XiaoQing235/ClevoFanControl/releases/download/v2.0.0/ClevoFanControl-v2.0.0-x64.zip'

# 补丁表。Offset 是**原始文件偏移**（不是 RVA）。Original / New 是 ASCII 字节串，
# 两者长度必须相等——就地覆盖，文件大小不变。
$Patches = @(
    [pscustomobject]@{
        Name     = 'A'
        Offset   = 0x1959C0
        Original = 'NP5SN'
        New      = 'P16P1'
        What     = '机型闸门字面量 "NP5"+"SN" -> "P16"+"P1"。注意 "P16" 本身含 "P1"，第二个条件恒真'
    }
    [pscustomobject]@{
        Name     = 'B'
        Offset   = 0x195174
        Original = 'dll'
        New      = 'bak'
        What     = 'Appx 分支的 PowerShell 字面量 .dll -> .bak，使分支① is_file() 落空'
    }
    [pscustomobject]@{
        Name     = 'C'
        Offset   = 0x1951D8
        Original = 'C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll'
        New      = $DLL_TARGET_PATH
        What     = '兜底路径改指向本机可加载的副本'
    }
)

# .NET Framework 没有 [Text.Encoding]::Latin1，用 ISO-8859-1（代码页 28591）：
# 它把字节 0x00-0xFF 一对一映射成字符，正好用来在 PS 字符串与字节间转换，
# 不像 UTF-8 那样会把单字节扩成多字节。
$Latin1 = [Text.Encoding]::GetEncoding(28591)

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-Sha256OfBytes {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try   { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Show-Hex {
    param([byte[]] $Bytes)
    return (($Bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')
}

function Resolve-ZipPath {
    param([string] $Given)
    if ($Given) {
        if (-not (Test-Path -LiteralPath $Given -PathType Leaf)) { throw "找不到 zip：$Given" }
        return (Resolve-Path -LiteralPath $Given).Path
    }
    $candidates = @(
        (Join-Path $scriptDir 'ClevoFanControl-v2.0.0-x64.zip'),
        (Join-Path $env:USERPROFILE 'Downloads\ClevoFanControl-v2.0.0-x64.zip')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    throw @"
找不到官方 zip（ClevoFanControl-v2.0.0-x64.zip）。
请手动下载：$UPSTREAM_URL
期望 SHA256：$EXPECTED_ZIP_SHA256
或用 -Zip 指定路径。
"@
}

Write-Host ''
Write-Host 'ClevoFanControl v2.0.0 -> P16 Pro IXA1 补丁器' -ForegroundColor Cyan
Write-Host ('-' * 68)

# ---------------------------------------------------------------------------
# 1. 机型
# ---------------------------------------------------------------------------
$model = $null
try {
    $cs    = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $model = $cs.Model
} catch { }

if ($model) {
    Write-Host ("机型 : {0}" -f $model)
    if ($model -notlike ('*{0}*' -f $EXPECTED_MODEL_FRAGMENT)) {
        if (-not $Force) {
            throw @"
机型不符：要求含 "$EXPECTED_MODEL_FRAGMENT"，实际是 "$model"。

这份适配只在蓝天 P16 Pro IXA1 上验证过，补丁 A 之后的闸门是
machine.contains("P16") —— 一个子串测试，不是机型白名单。EC 固件侧的语义
（0xC1 逐通道命令、0x69 位掩码、to_raw 换算、缓冲区偏移）在别的机型上
完全没有验证过，而作者设那道闸门正是为了挡住这个风险。

确认是同一机型但 SMBIOS 字符串不同，再加 -Force。
"@
        }
        Write-Host '  ↳ 含 -Force，跳过机型检查（风险自负）' -ForegroundColor Yellow
    }
} else {
    Write-Host '机型 : <读不到 Win32_ComputerSystem.Model>' -ForegroundColor Yellow
    if (-not $Force) { throw '读不到机型，无法核对。确认无误后加 -Force 继续。' }
}

$bios = $null
try { $bios = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion } catch { }
if ($bios) { Write-Host ("BIOS : {0}" -f $bios) }

# ---------------------------------------------------------------------------
# 2. zip 哈希
# ---------------------------------------------------------------------------
$zipPath = Resolve-ZipPath -Given $Zip
Write-Host ("zip  : {0}" -f $zipPath)

$zipHash = Get-Sha256 -Path $zipPath
if ($zipHash -ne $EXPECTED_ZIP_SHA256) {
    throw @"
zip 哈希不符，拒绝继续。
  期望 $EXPECTED_ZIP_SHA256
  实际 $zipHash
这不是 v2.0.0 官方发布的那份 zip（或者下载不完整/被改动过）。
重新下载：$UPSTREAM_URL
"@
}
Write-Host '  ↳ zip SHA256 与官方 digest 一致' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. 解包并校验原始 exe
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tmp = Join-Path $env:TEMP ('cfc-patch-{0}' -f $PID)
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

try {
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tmp)
    $srcExe = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'clevo-fan-control.exe' |
              Select-Object -First 1
    if (-not $srcExe) { throw "zip 里找不到 clevo-fan-control.exe：$zipPath" }

    $srcHash = Get-Sha256 -Path $srcExe.FullName
    if ($srcHash -ne $EXPECTED_SRC_SHA256) {
        if ($srcHash -eq $EXPECTED_OUT_SHA256) {
            throw @"
这个 zip 里的 exe 已经是打过补丁的版本了，不能再打一遍。
（它的 SHA256 等于产物哈希 $EXPECTED_OUT_SHA256）
请改用未经改动的官方 zip：$UPSTREAM_URL
"@
        }
        throw @"
zip 内 exe 哈希不符，拒绝继续。
  期望 $EXPECTED_SRC_SHA256
  实际 $srcHash
补丁按绝对偏移定位，只能施加在这一份确定的二进制上。上游一旦发新版，
偏移必然失效——不要在新版本上试。
"@
    }
    Write-Host '  ↳ 原始 exe SHA256 一致' -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 4. 逐字节校验三个偏移处的原始内容
    # -----------------------------------------------------------------------
    $bytes = [IO.File]::ReadAllBytes($srcExe.FullName)
    if ($bytes.Length -ne $EXPECTED_OUT_LENGTH) {
        throw "exe 长度 $($bytes.Length) 与预期 $EXPECTED_OUT_LENGTH 不符。"
    }

    Write-Host ''
    Write-Host '逐字节校验：'
    foreach ($p in $Patches) {
        $want = $Latin1.GetBytes($p.Original)
        $got  = $bytes[$p.Offset..($p.Offset + $want.Length - 1)]

        if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$got, [byte[]]$want)) {
            throw @"
补丁 $($p.Name) 的原始字节不符，拒绝继续。
  偏移 0x$('{0:x}' -f $p.Offset)  长度 $($want.Length)
  期望 $($p.Original)
  实际 $($Latin1.GetString([byte[]]$got))
  字节 期望 $(Show-Hex $want)
       实际 $(Show-Hex $got)
"@
        }
        Write-Host ("  [{0}] 0x{1:x} len={2,-3} 原始相符  {3}" -f `
            $p.Name, $p.Offset, $want.Length, $p.Original) -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # 5. 就地覆盖
    # -----------------------------------------------------------------------
    foreach ($p in $Patches) {
        $new = $Latin1.GetBytes($p.New)
        [Array]::Copy($new, 0, $bytes, $p.Offset, $new.Length)
    }
    Write-Host ''
    Write-Host '已写入：' -ForegroundColor Green
    foreach ($p in $Patches) {
        $new = $Latin1.GetBytes($p.New)
        Write-Host ("  [{0}] 0x{1:x}  {2}" -f $p.Name, $p.Offset, $p.New) -ForegroundColor Green
        Write-Host ("       {0}" -f $p.What) -ForegroundColor DarkGray
    }

    # -----------------------------------------------------------------------
    # 6. 模拟补丁 C 的运行时拼接
    #
    # Rust 把这条 51 字节字面量做了常量折叠：只前 48 字节从 .rdata 用 SSE 拷走，
    # 偏移 47..50 的 ".dll" 在运行时由 MOV dword [rax+0x2f], 0x6c6c642e 写死。
    # 所以替换路径必须仍是 51 字节、且 ".dll" 正好落在偏移 47。
    # -----------------------------------------------------------------------
    $pc   = $Patches | Where-Object { $_.Name -eq 'C' }
    $lit  = [byte[]]$bytes[$pc.Offset..($pc.Offset + 46)]      # 运行时从 .rdata 读走的部分
    $imm  = [byte[]]$bytes[($pc.Offset + 47)..($pc.Offset + 50)]  # 运行时由立即数写死的部分

    if ($Latin1.GetString($imm) -ne '.dll') {
        throw "补丁 C 偏移 47..50 不是 '.dll'，而是 '$($Latin1.GetString($imm))' —— 运行时拼出来的路径会是坏的。"
    }
    $runtime = $Latin1.GetString($lit) + $Latin1.GetString($imm)
    if ($runtime -ne $DLL_TARGET_PATH) {
        throw @"
补丁 C 的运行时拼接结果与目标路径不符。
  拼接 $runtime
  目标 $DLL_TARGET_PATH
"@
    }
    Write-Host ''
    Write-Host ("运行时拼接：{0}  == 目标路径" -f $runtime) -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 7. 产物哈希 —— 决定性的一步
    # -----------------------------------------------------------------------
    $outHash = Get-Sha256OfBytes -Bytes $bytes
    if ($outHash -ne $EXPECTED_OUT_SHA256) {
        throw @"
产物哈希不符，拒绝写出。
  期望 $EXPECTED_OUT_SHA256
  实际 $outHash
补丁逻辑与记录不一致。不要使用这个结果，请核对 PATCH-NOTES.md。
"@
    }
    Write-Host ''
    Write-Host ("产物 SHA256 {0}" -f $outHash) -ForegroundColor Green
    Write-Host '  ↳ 与已适配 exe 逐位一致' -ForegroundColor Green

    # -----------------------------------------------------------------------
    # 8. 写出
    # -----------------------------------------------------------------------
    if ($Verify) {
        Write-Host ''
        Write-Host '（-Verify）未写出产物。' -ForegroundColor Cyan
    } else {
        if (-not (Test-Path -LiteralPath $OutDir)) {
            New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        }
        $outExe = Join-Path $OutDir 'clevo-fan-control.exe'
        [IO.File]::WriteAllBytes($outExe, $bytes)
        Write-Host ''
        Write-Host ("已写出 {0}  ({1} 字节)" -f $outExe, $bytes.Length) -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # 后续步骤
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host ('-' * 68)
    Write-Host '下一步：' -ForegroundColor Cyan
    Write-Host '  1. 铺厂商 DLL（程序唯一的外部依赖）：'
    Write-Host '       powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-dll.ps1'
    Write-Host ("     目标 $DLL_TARGET_PATH")
    Write-Host ("     SHA256 $EXPECTED_DLL_SHA256")
    Write-Host '  2. 把产物和 ClevoFanControl.x64.json 放同一目录（配置必须和 exe 同目录）。'
    Write-Host '  3. 先只跑只读诊断核对读数，不要一上来就开接管：'
    Write-Host '       $p = Start-Process .\clevo-fan-control.exe -ArgumentList "--probe" -Wait -PassThru `'
    Write-Host '            -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"'
    Write-Host '       Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"'
    Write-Host '     若报「DLL 版本尚未验证」→ 路径补丁生效了，只是 DLL 副本没放对（第 1 步）。'
    Write-Host ''
    Write-Host '风险提示：' -ForegroundColor Yellow
    Write-Host '  接管打开后 EC 会锁存占空比，进程崩溃/被强杀会把风扇留在最后那个值上。' -ForegroundColor Yellow
    Write-Host '  回退只有 Control Center（Fn 热键）或重启两条路。' -ForegroundColor Yellow
    Write-Host ''
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
