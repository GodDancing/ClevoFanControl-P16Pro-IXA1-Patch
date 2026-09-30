# 本机适配补丁说明（P16 Pro IXA1）

对上游 `ClevoFanControl v2.0.0` 的两处适配，共 3 个补丁、**37 个实际变化的字节**。

- 补丁 A：绕开机型闸门（原始字面量 5 字节）
- 补丁 B/C：绕开被 ACL 锁死的 DLL 路径，改从本机可加载的副本读取（原始字面量 3 + 51 字节）

> **字节数别混。** 补丁 C 的字面量是 51 字节，但两条路径**意外共享**了开头的 `C:\Program`、
> 中间的 `Control` 和结尾的 `.dll`，所以**只有 29 个字节真的不同**。37 = 5 + 3 + 29。
> 已用原始 zip（`9db6d1e3…`）与产物（`8bc9d401…`）逐字节 diff 实测确认。
>
> 这直接决定补丁器怎么写：**必须逐字节校验完整的字面量**，只比"变化的区间"等于自废校验
> —— 它会放过任何把那 29 个字节改成第三样东西的输入。
>
> 可复现的补丁器见 `apply-patch.ps1`：它对原始 zip 施加本文件描述的 3 处覆盖，并逐级校验
> （zip 哈希 → exe 哈希 → 三个偏移的完整原始字节 → 补丁 C 的运行时拼接 → 产物哈希）。

`.text` / `.pdata` / `.rsrc` / `.reloc` 四个节**逐字节未改动**，文件大小不变（2,491,392 字节），PE 结构完好（x64、Subsystem=2 GUI、6 个节）。

## 源包

- 文件：`ClevoFanControl-v2.0.0-x64.zip`
- 来源：https://github.com/XiaoQing235/ClevoFanControl/releases/download/v2.0.0/ClevoFanControl-v2.0.0-x64.zip
- SHA256：`a0032bbfdc2aa85ec24cd6c449ec386a548b1b00648511ae18c43345912cb1ac`
  （与 GitHub API 返回的官方 digest 逐位一致）

---

## 补丁 A：机型闸门（偏移 `0x1959c0`，5 字节）

上游 `hardware.rs:37` 硬编码只支持 NP5x_6x_7x_SNx：

```rust
if !machine.contains("NP5") || !machine.contains("SN") {
    return Err(format!("尚未验证机型 {machine} 的 EC 映射；当前仅支持 NP5x_6x_7x_SNx"));
}
```

编译后这两个字面量在 `.rdata` 紧邻存放，被两处 `LEA rcx,[rip+…]` 引用：

```
.text+0x28ed8   48 8d 0d e1 c6 16 00   LEA rcx,[rip+0x16c6e1] -> 0x1401965c0  ("NP5", len=3)
                ba 03 00 00 00         MOV edx,3   ; CALL str::contains ; TEST al,al / JE
.text+0x28efc   48 8d 0d c0 c6 16 00   LEA rcx,[rip+0x16c6c0] -> 0x1401965c3  ("SN",  len=2)
                ba 02 00 00 00         MOV edx,2   ; CALL str::contains ; TEST al,al / JE
```

| | 字节 | 含义 |
|---|---|---|
| 前 | `4e 50 35 53 4e` = `NP5SN` | `"NP5"` + `"SN"` |
| 后 | `50 31 36 50 31` = `P16P1` | `"P16"` + `"P1"` |

`"P16 Pro IXA1"` 同时含 `"P16"` 和 `"P1"`，闸门放行。

全镜像扫描：指向这两个地址的引用**只有上述 2 处**，都是 `LEA rcx`。报错文本里另有一份 `NP5x_6x_7x_SNx`（偏移 1661436），无任何代码引用，未改动。

---

## 补丁 B/C：为什么必须改，以及改了什么

### 症状与根因

运行后 `exit=1 / LoadLibraryExW failed`。根因不在 flags、不在缺依赖、不在补丁 A：

```
C:\Program Files\WindowsApps\CLEVOCO.FnhotkeysandOSD_7.62.3.0_x64__6h6z29zh29qx0\FnKey\InsydeDCHU.dll
```

这个目录的 ACL 给 `Users` 只有 **Read**，没有 **FILE_EXECUTE**：

```
GENERIC_READ      GRANTED
GENERIC_EXECUTE   DENIED (err=5)
READ|EXECUTE      DENIED
```

`LoadLibraryExW` 的 **7 种 flag 组合全部失败**（含 `flags=0`），一律 `ERROR_ACCESS_DENIED(5)`。
`std::fs::read` 只要 Read，所以哈希校验能过；`LoadLibraryEx` 需要 FILE_EXECUTE，所以加载不了。
FnKey.exe 能加载它，是因为它属于该 Appx 包。

**修 ACL 这条路走不通**：对该文件 `CreateFileW` 请求 `WRITE_DAC` 和 `WRITE_OWNER` 都是 `DENIED(5)`，`icacls /grant` 和 `takeown` 都无从下手（需要 TrustedInstaller 级权限）。

已验证的替代事实：把同一份 DLL 复制到普通目录后 `LoadLibraryExW(0x900)` **加载成功**（`handle=0x7ffe97570000`）——即该 DLL 不依赖 `FnKey` 目录里的其它文件。

### 上游 `platform.rs::find_dll()` 逻辑

```rust
let p = run("powershell.exe", &[..., "Get-AppxPackage '*FnhotkeysandOSD*' | ForEach-Object \
         { Join-Path $_.InstallLocation 'FnKey\\InsydeDCHU.dll' } | Select-Object -First 1"])?;  // 分支①
let path = PathBuf::from(p.trim());
if path.is_absolute() && path.is_file() { return Ok(path); }     // 命中被 ACL 锁死的 WindowsApps
let path = PathBuf::from(r"C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll");  // 分支②
if path.is_file() { Ok(path) } else { Err("未找到官方 x64 InsydeDCHU.dll，请先安装 Control Center 驱动") }
```

### 补丁 B：让分支①落空（偏移 `0x195174`，3 字节）

把 PowerShell 命令里的 `FnKey\InsydeDCHU.dll` 改成 `FnKey\InsydeDCHU.bak`（等长，`dll`→`bak`）。
`Join-Path` 不校验存在性，输出仍是绝对路径，但 `is_file()` 为假 → 落到分支②。

该命令是 `.rdata` 里一条 133 字节的字面量，由 `(ptr,len)` 表项（raw `0x1951c8`）整体引用；`FnKey\InsydeDCHU.dll` 在命令内**只出现 1 次**（镜像里另一处 20 字节副本在偏移 1727680，是界面说明文字，未改动）。

改后命令实际读作：

```
Get-AppxPackage '*FnhotkeysandOSD*' | ForEach-Object { Join-Path $_.InstallLocation 'FnKey\InsydeDCHU.bak' } | Select-Object -First 1
```

### 补丁 C：把分支②指向本机可加载的副本（偏移 `0x1951d8`，51 字节）

| | 内容 |
|---|---|
| 前 | `C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll` |
| 后 | `C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll` |

**这里有个坑，必须记录。** Rust 把这条 51 字节字面量做了常量折叠：只前 48 字节从 `.rdata` 用 SSE 拷走，**最后 4 字节（偏移 47..50）在运行时由立即数写死**：

```
.text+0x1bb38  41 b8 33 00 00 00      MOV r8d, 51                      ; 长度 = 51
.text+0x1bb4d  0f 10 05 a4 92 17 00   MOVUPS xmm0,[rip+0x1792a4]       ; 字面量 32..47
               0f 11 40 20            MOVUPS [rax+0x20],xmm0
.text+0x1bb55  0f 10 05 89 92 17 00   MOVUPS xmm0,[rip+0x179289]       ; 字面量 16..31
               0f 11 40 10            MOVUPS [rax+0x10],xmm0
.text+0x1bb5d  0f 10 05 6e 92 17 00   MOVUPS xmm0,[rip+0x17926e]       ; 字面量  0..15
               0f 11 00               MOVUPS [rax],xmm0
               c7 40 2f 2e 64 6c 6c   MOV dword [rax+0x2f], 0x6c6c642e  ; 偏移 47 硬写 ".dll"
```

所以替换路径**必须仍然以 `.dll` 结尾、且 `.dll` 正好落在偏移 47**，否则运行时拼出来的字符串是坏的。

`C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll`：

```
偏移  0..30  C:\ProgramData\ClevoFanControl\      31 字符
偏移 31..46  InsydeDCHU-FnKey                     16 字符
偏移 47..50  .dll                                  4 字符   <- 与立即数一致
             ------------------------------------
             合计 51 字符
```

已按 `(patched[0:47] + b".dll")` 模拟运行时拼接，结果与目标路径完全一致。
（`platform.rs` 里的短字面量 `.dll` 被 LLVM 复用成了这个立即数，这也是为什么 `.rdata` 里只有前 48 字节被 SSE 读取。）

### 需要放到位的文件

```
C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll
SHA256 75a47020d3a9d052e94dcb4e3ad61fb69f20177dd46e20c9a20883d92b83981b
```

来源就是上面那个 WindowsApps 里的 `FnKey\InsydeDCHU.dll`（**只读复制**，原文件未动、ACL 未动）。
这个哈希**本来就在程序白名单内**（`hardware.rs:52-56` 两个哈希之一），所以**白名单未改动**。

> 另一条可行路线（未采用）：把 `22fecadf…65a9d47` 这个白名单哈希换成 `C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll` 的 `430d522c811a5df1037d07714c47316967c015391985e3f9a0915eefc46d328f`，直接加载 Control Center 那份 DLL。
> 没选它，因为那是 2024-08-09 的另一份构建（2,653,336 字节，与 WindowsApps 那份 2,503,008 字节不同源），**不在作者验证过的白名单里**，而白名单的用意正是"只加载作者验证过的二进制"。现方案保留了这个语义。

### 分支复现验证（不运行程序、不碰 EC）

用真实 PowerShell 跑补丁后的两条判断：

```
Appx branch returns : C:\Program Files\WindowsApps\CLEVOCO.FnhotkeysandOSD_7.62.3.0_x64__6h6z29zh29qx0\FnKey\InsydeDCHU.bak
  is_absolute       : True
  is_file (须为 F)   : False        <- 落空，进入分支②
fallback path       : C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll
  is_file (须为 T)   : True
  length            : 51
  char[47..50]      : .dll
```

---

## 哈希

| 文件 | SHA256 |
|---|---|
| 原始 zip | `a0032bbfdc2aa85ec24cd6c449ec386a548b1b00648511ae18c43345912cb1ac` |
| 原始 exe | `9db6d1e39eed0f7b1df765856235fef58f6f758d63a4bd2aa9b26a8ce07bce71` |
| **本目录 exe（已改）** | `8bc9d40104babf90bc2aaa0c987424eb7ec5b3a25173a0d8fbc49f837c559a69` |
| 本机 DLL 副本 | `75a47020d3a9d052e94dcb4e3ad61fb69f20177dd46e20c9a20883d92b83981b` |

已改过的 exe 与原始 release 不再同源，**不要再拿它跟官方哈希对比**。

原始 zip 未改动，现在在 `%USERPROFILE%\Downloads\ClevoFanControl-v2.0.0-x64.zip`
（1,299,538 字节，SHA256 已核对为 `a0032bbf…`）。**这份 zip 要自己留好** —— 它是回退的唯一来源，
也是 `apply-patch.ps1` 重新生成已适配 exe 的唯一输入。上游一旦发新版，补丁按绝对偏移会全部失效。

## 本机固件比对结果（支持可行性，但未证完）

| 检查项 | 作者机器 | 本机（P16 Pro IXA1） |
|---|---|---|
| DCHU `_DSM` UUID `93f224e4-fbdc-4bbf-add6-db71bdc0afad` | 有 | **有** |
| ACPI 方法 `PK04` / `ECMD` / `CPKG` / `SCMD` / `CC30` | 有 | **有** |
| 设备 `ACPI\CLV0001\1` / `CLV0002\1` | 有 | **有**（AcpiBridge 驱动运行中） |
| `InsydeDCHU.dll` | `…7.88.1.0…` | `…7.62.3.0…`，**DLL 二进制哈希相同** |

软件层与 ACPI 接口层一致。**未验证**的是 PK04 背后 EC 固件侧的语义——`0xC1` 逐通道命令、`0x69` 恢复自动的位掩码、`to_raw` 占空比换算、缓冲区偏移（`18+i*3` 温度 / `16+i*3` 实际占空比、`2+i*2` 转速）。这些在 EC 固件里，静态分析无法确认，作者设那道机型闸门正是为此。**机型闸门是被我们主动拆掉的，风险随之转移到这里。**

## 建议的验证顺序

程序自带运行时兜底：风扇数量必须落在 1..=3，温度必须落在 1..=125，否则报错停止而不是拿垃圾值去控风扇。

Release 版是 GUI 子系统（`Subsystem=2`），**没有控制台**，直接双击 / 命令行运行都不会有输出，并且 shell 不会等它。要拿输出必须重定向：

```powershell
$p = Start-Process -FilePath "%USERPROFILE%\Downloads\ClevoFanControl-v2.0.0-p16pro\clevo-fan-control.exe" -ArgumentList "--probe" -Wait -PassThru -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"; "exit=$($p.ExitCode)"; Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"
```

1. **先跑只读诊断**（真实硬件只读采样，不写 EC），核对风扇数量、温度、转速是否与 Control Center 显示的一致。上一步失败时，若报错变成 `DLL 版本尚未验证：C:\ProgramData\…`，说明路径补丁生效、只是 DLL 副本没放对。
2. 一致后再打开界面，**保持"软件接管"关闭**，只观察。
3. 确认无误再启用接管。曲线务必按本机散热能力调。
4. **不要**一上来就跑 `--hardware-check`（README 明确说明它会真的改占空比）。
5. 若第 1 步的读数与 Control Center 不一致，**立即停止一切写入**。

注意：manifest 是 `requireAdministrator`，运行会弹 UAC。作者**不保证**崩溃 / 强杀 / 驱动挂起时恢复固件自动控制；需要时用 Control Center 或重启拿回控制权。若在界面里开了自启动，会创建计划任务 `ClevoFanControl`（删除：`schtasks /Delete /TN ClevoFanControl /F`）。

## 回退

- 恢复出厂 exe：从 `%USERPROFILE%\Downloads\ClevoFanControl-v2.0.0-x64.zip` 重新解压即可，
  原始包未被改动（哈希 `a0032bbf…` 可自证）。**这一份就是恢复出厂，不需要任何别的备份。**
  已解包好的副本也在：`%USERPROFILE%\Downloads\ClevoFanControl-v2.0.0-x64\clevo-fan-control.exe`
  （`9db6d1e3…`，与 zip 内一致）。
- 重新打补丁：`powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-patch.ps1`
  产物应得 `8bc9d401…`。哈希不符就说明补丁逻辑与记录不一致，**不要用那个结果**。
- 撤掉 DLL 副本：`Remove-Item "C:\ProgramData\ClevoFanControl" -Recurse`。
  该目录是本方案唯一新增的落盘位置，删掉即完全还原（WindowsApps 原文件与 ACL 全程未动）。
