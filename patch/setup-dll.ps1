<#
  恢复 ClevoFanControl 运行所需的厂商 DLL 副本。

  为什么需要它：程序不能直接加载 WindowsApps 里的原件——那个目录只给
  Users 读权限，没有执行权限，LoadLibraryEx 会以 ERROR_ACCESS_DENIED(5) 失败。
  所以必须把同一份 DLL 复制到普通目录，程序才会从副本加载。

  本脚本做两件事：在候选来源里挑出**程序白名单认得的**那一份，复制到目标路径并校验哈希。
  不会修改 WindowsApps 里的原文件，也不会改动任何 ACL。

  用法（普通权限即可）：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-dll.ps1
#>
[CmdletBinding()]
param(
    [string] $Destination = 'C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 程序内置白名单：exe 的 .rdata 里恰好有这两个 SHA256 字面量
# （偏移 0x195a29 与 0x195a69，对应 hardware.rs 里的两张白名单表）。
# 副本哈希命中其中之一，程序就会加载它——所以本脚本接受两者，不再只认 FnKey 那一份。
#
# 只认一份的后果不是"更安全"，而是把一台**本来可用**的机器挡在门外：
# 同型号但 FnKey 组件版本不同的机器，其 DLL 可能是第二个哈希，
# 程序会接受，而本脚本会报"哈希不符"。
#
# 注意：这条路径必须与补丁 C 一致——补丁 C 把兜底路径改成了
# C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll，就是本脚本的 $Destination。
# ---------------------------------------------------------------------------
$accepted = @(
    [pscustomobject]@{
        Hash = '75A47020D3A9D052E94DCB4E3AD61FB69F20177DD46E20C9A20883D92B83981B'
        Name = 'FnKey 包里的 InsydeDCHU.dll'
    }
    [pscustomobject]@{
        Hash = '22FECADFF27F4BF08CB4A17FE455AE490107B409E55827210F821947D65A9D47'
        Name = '白名单里的另一份 InsydeDCHU.dll'
    }
)

function Resolve-WhitelistEntry {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Hash)
    return $accepted | Where-Object { $_.Hash -eq $Hash } | Select-Object -First 1
}

function Get-Hash {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

Write-Host ''
Write-Host 'ClevoFanControl 厂商 DLL 铺设' -ForegroundColor Cyan
Write-Host ('-' * 68)

# ---------------------------------------------------------------------------
# 已经在位？
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $Destination) {
    $cur = Get-Hash -Path $Destination
    $m   = Resolve-WhitelistEntry -Hash $cur
    if ($m) {
        Write-Host "已就绪，无需处理。" -ForegroundColor Green
        Write-Host "  路径   $Destination"
        Write-Host "  SHA256 $cur"
        Write-Host "  白名单 $($m.Name)"
        exit 0
    }
    Write-Host "现有副本哈希不在白名单内，将重新铺设：" -ForegroundColor Yellow
    Write-Host "  $cur"
}

# ---------------------------------------------------------------------------
# 收集候选来源
#
# 用 Get-AppxPackage 查包注册库——不要枚举 C:\Program Files\WindowsApps，
# 该目录不允许列出，Get-ChildItem 只会返回空。
# ---------------------------------------------------------------------------
$candidates = @()

$candidates += @(Get-AppxPackage '*FnhotkeysandOSD*' -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.InstallLocation 'FnKey\InsydeDCHU.dll' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

# 兜底来源：Control Center 驱动栈里的那份（上游 find_dll() 的备用路径）。
$cc = 'C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll'
if (Test-Path -LiteralPath $cc -PathType Leaf) { $candidates += $cc }

if (-not $candidates) {
    throw @"
没找到任何候选 DLL。
请先确认官方 FnKey / Control Center 组件已安装（任一即可）。
"@
}

# ---------------------------------------------------------------------------
# 逐个哈希，选出白名单认得的那一份
# ---------------------------------------------------------------------------
$found = @()
$src = $null
foreach ($c in $candidates) {
    $h = Get-Hash -Path $c
    $m = Resolve-WhitelistEntry -Hash $h
    $found += [pscustomobject]@{ Path = $c; Hash = $h; Entry = $m }
    if ($m -and -not $src) { $src = $c }
}

if (-not $src) {
    $wantLines = ($accepted | ForEach-Object { "  $($_.Hash)   ($($_.Name))" }) -join "`n"
    $gotLines  = ($found    | ForEach-Object { "  $($_.Hash)   $($_.Path)" }) -join "`n"
    throw @"
找到的 DLL 没有一份在程序白名单内，无法铺设。
白名单只有这两个哈希：
$wantLines

实际找到：
$gotLines

如果刚更新过 FnKey / Control Center，DLL 二进制可能已经换了版本——
此时需要重新核对程序白名单（hardware.rs），不能只靠本脚本。
"@
}

$srcHash  = Get-Hash -Path $src
$srcEntry = Resolve-WhitelistEntry -Hash $srcHash

Write-Host ''
Write-Host '候选来源：'
foreach ($f in $found) {
    $tag = if ($f.Entry) { "白名单 OK  ($($f.Entry.Name))" } else { '不在白名单' }
    $mark = if ($f.Path -eq $src) { '->' } else { '  ' }
    Write-Host ("  {0} {1}" -f $mark, $f.Path) -ForegroundColor $(if ($f.Entry) { 'Green' } else { 'DarkGray' })
    Write-Host ("       {0}  {1}" -f $f.Hash, $tag) -ForegroundColor $(if ($f.Entry) { 'Green' } else { 'DarkGray' })
}

# ---------------------------------------------------------------------------
# 复制并复核
# ---------------------------------------------------------------------------
$parent = Split-Path -Parent $Destination
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

Copy-Item -LiteralPath $src -Destination $Destination -Force

$got = Get-Hash -Path $Destination
if ($got -ne $srcHash) {
    throw "复制后哈希与来源不符，落盘可能被拦截。`n  来源 $srcHash`n  副本 $got"
}
if (-not (Resolve-WhitelistEntry -Hash $got)) {
    throw "复制后哈希不在白名单内（$got），程序会拒绝加载。"
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
Write-Host "  路径   $Destination"
Write-Host "  SHA256 $got"
Write-Host "  白名单 $($srcEntry.Name)"
Write-Host "  来源   $src"
Write-Host ''
Write-Host '这一步只是把厂商 DLL 复制到程序认得的位置，不碰 EC、不写风扇。' -ForegroundColor DarkGray
