# 快速上手：从零到用上

面向 **蓝天 P16 Pro IXA1 机主**的完整操作流程。假设你手上只有从上游 GitHub 下载的
`ClevoFanControl-v2.0.0-x64.zip`，且**需要你先确认它的完整路径**。

全程约 10 分钟。命令都在 **PowerShell** 里执行（开始菜单搜 `PowerShell`，**不需要**管理员权限，
除了最后实际运行程序那一步要管理员）。

---

## 最快的路：双击 `install.bat`

已经拿到本仓库、也知道 zip 在哪个目录的话，**双击仓库根目录的 `install.bat`** 就够了。
它会问你 zip 路径，然后自动走完下面的第 0～5 步（打补丁、铺 DLL、放配置，可选做只读验证），
任一环节失败就中止、不产出半成品。

也可以把 zip 文件**直接拖到 `install.bat` 上**，路径会自动传进去。

> 想以管理员身份运行（这样能顺便自动完成第 4 步的只读验证）：右键 `install.bat` →
> **以管理员身份运行**。

下面是逐步的完整说明，讲清每一步在做什么、为什么这么做。想弄明白细节就往下读。

---

## 先过两道硬门槛（1 分钟，决定你能不能继续）

这份补丁**只对一种机器有效**。先花一分钟确认，不满足就直接停，别往下走。

### 门槛 1：机型字符串必须含 `P16`

```powershell
(Get-CimInstance Win32_ComputerSystem).Model
```

- 输出含 `P16`（例如 `P16 Pro IXA1`）→ ✅ 继续
- 输出别的（含 `NP5`、`NP6` 等）→ ❌ **停下**。上游原版本来支持那些机型，你直接用官方原版即可，
  不需要这份补丁，更不该套用它。
- 输出 `System Product Name` 之类的通用串（部分是刷过 BIOS 的机器）→ ❌ 停下，别猜。

### 门槛 2：FnKey 组件的版本必须对得上

程序卡的是 **DLL 的哈希**，不是机型字符串。所以这一步比机型检查更硬：

```powershell
$dll = Join-Path (Get-AppxPackage '*FnhotkeysandOSD*').InstallLocation 'FnKey\InsydeDCHU.dll'
(Get-FileHash $dll -Algorithm SHA256).Hash
```

| 结果 | 含义 |
|---|---|
| `75A47020D3A9D052E94DCB4E3AD61FB69F20177DD46E20C9A20883D92B83981B` | ✅ **本仓库验证过的唯一情况**（FnKey `7.62.3.0`），继续 |
| `22FECADFF27F4BF08CB4A17FE455AE490107B409E55827210F821947D65A9D47` | ⚠️ 这是程序白名单里的另一份，理论上能加载，但**本仓库未验证**，风险自负 |
| 其他任何值 | ❌ **停下**。程序会直接拒绝加载这份 DLL，且这跟补丁无关，改不了 |
| 命令报错 | 说明 FnKey 组件没装，先装官方 Control Center / FnKey 包 |

> 程序内置白名单只有上面两个哈希。FnKey 一旦升级换代，DLL 二进制变了，这份补丁就用不了了。

---

## 第 0 步：准备好 zip 的完整路径

**这一步的路径由你提供，脚本不会替你去翻硬盘。** 它只认你给的那一个路径，
找不到就直接报错——不猜测、不搜索、不遍历目录。

所以先自己确认好，再往下走。

### 路径长这样

```text
C:\Users\<你的用户名>\Downloads\ClevoFanControl-v2.0.0-x64.zip
```

### 想不起来放哪了怎么办

最可靠的一条路，不需要任何命令：

- Edge / Chrome 按 `Ctrl + J` 打开下载记录
- 找到 `ClevoFanControl-v2.0.0-x64.zip` 那一行 → 右键 → **在文件夹中显示**
- 弹出的地址栏里就是目录，加上文件名就是完整路径

### 拿到路径后：确认它是**原件**

这一步别跳过。网上流传的包可能被改过或下载不完整：

```powershell
(Get-FileHash "把第 0 步确认好的完整路径粘到这里" -Algorithm SHA256).Hash
```

必须**一字不差**等于：

```
A0032BBFDC2AA85EC24CD6C449EC386A548B1B00648511AE18C43345912CB1AC
```

对不上就重新下载。**认准这个哈希**——它是后面一切校验的基准。

> **这个 zip 请永久留好。** 它是你唯一的回退来源（出问题就靠它还原），也是重新打补丁的唯一输入。
> 上游哪天删了 release 就再也下不到了。建议复制一份到别处。

---

## 第 1 步：拿到本仓库

把仓库放到你喜欢的目录即可，例如：

```powershell
git clone <仓库地址> C:\ClevoFanControl-P16Pro-IXA1-Patch
```

后面所有命令都在**仓库根目录**（含 `README.md` 的那一层）执行。本文档里的 `.\patch\...`
都是相对仓库根目录的路径。

---

## 第 2 步：打补丁（产出适配版 exe）

zip **放在哪都行**，下面命令用 `-Zip` 显式指定。先把第 0 步确认好的路径存成变量，省得反复粘贴：

```powershell
$zip = "C:\Users\你的用户名\Downloads\ClevoFanControl-v2.0.0-x64.zip"   # ← 换成第 0 步确认的完整路径
```

**先空转**——只校验、不写出产物（中途会在 `%TEMP%` 下临时解包，退出时清理）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1 -Zip $zip -Verify
```

看到这一行就说明全过：

```
产物 SHA256 8BC9D40104BABF90BC2AAA0C987424EB7EC5B3A25173A0D8FBC49F837C559A69
  ↳ 与已适配 exe 逐位一致
（-Verify）未写出产物。
```

然后**正式跑**（去掉 `-Verify`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1 -Zip $zip
```

产物：`patch\build\clevo-fan-control.exe`

脚本会依次校验 6 项，**任何一项不符就中止、不产出半成品**：机型含 `P16` → zip 的 SHA256 →
zip 内 exe 的 SHA256 → 三个偏移处的完整原始字面量 → 补丁 C 的运行时拼接结果 → **产物 SHA256**。

> 报 `机型不符` 但你的机器确实含 `P16`？那是读不到 SMBIOS 的情况，加 `-Force` 跳过——除非你
> 确定是同一机型，否则别加。
>
> 报 `zip 内 exe 哈希不符`？说明这不是 v2.0.0 官方原件，回去重下。

---

## 第 3 步：铺厂商 DLL

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\setup-dll.ps1
```

这一步只做一件事：把本机 FnKey 包里的 `InsydeDCHU.dll` **复制**一份到
`C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll`。

**为什么必须复制**：程序不能直接加载 WindowsApps 里的原件——那个目录只给 `Users` 读权限、
没有执行权限，`LoadLibraryEx` 会以 `ERROR_ACCESS_DENIED(5)` 失败。而且改 ACL 也走不通
（需要 TrustedInstaller 级权限）。

脚本**不修改原文件、不改任何 ACL、不外传**，只是复制。这符合厂商组件的许可要求。

成功输出：

```
完成。
  路径   C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll
  白名单 FnKey 包里的 InsydeDCHU.dll
```

---

## 第 4 步：只读验证（**最关键的一步，别跳**）

程序是 GUI 子系统，**没有控制台**：直接双击或从命令行跑都不会有任何输出。必须重定向才能拿到：

```powershell
cd .\patch\build
$p = Start-Process .\clevo-fan-control.exe -ArgumentList "--probe" -Wait -PassThru `
     -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"
"exit=$($p.ExitCode)"
Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"
```

`--probe` 是**纯只读采样，不写 EC**，安全。

然后**逐项核对**：风扇数量、各通道温度、转速，与蓝天 Control Center（Fn 热键打开）**是否一致**。

| 结果 | 下一步 |
|---|---|
| 读数逐项一致，`exit=0` | ✅ 进第 5 步 |
| 报 `DLL 版本尚未验证：C:\ProgramData\…` | 补丁生效了，只是 DLL 没放对 → 回第 3 步 |
| 读数与 Control Center **不一致** | ❌ **立即停止一切写入操作**。说明 EC 语义与本方案假设不符 |

---

## 第 5 步：配置并启用

### 5.1 写配置

配置文件名**必须**是 `ClevoFanControl.x64.json`，并且**和 exe 放在同一目录**才会被自动加载：

```powershell
Copy-Item .\ClevoFanControl.x64.example.json .\patch\build\ClevoFanControl.x64.json
```

仓库给的示例刻意写成 `takeOver: false` + `autoRun: false`（不接管、不自启），**这是安全的起点**。
曲线请按自己机器的散热能力调，参考 `docs/curve.md`。

> ⚠️ **绝对不要用程序内置的默认曲线。** 它是 45–90 °C 全部 40% 的平直线——接管一开就等于把两个
> 风扇钉在 40%，到 90 °C 也不升。

### 5.2 先只观察，不接管

管理员身份运行 `clevo-fan-control.exe`，打开界面后：

1. **保持「软件接管」关闭**，只观察读数是否随负载正常变化
2. 确认无误后，再打开「软件接管」
3. 观察一段时间，确认风扇按你的曲线走

### 5.3 四条"别做"

- ❌ **别碰 `--hardware-check`** —— 它会真的改风扇占空比，不是普通测试命令
- ❌ **别按界面里的「强制冷却」** —— 它往所有通道写 95%，**即使接管是关的**
- ❌ **别让两个实例同时跑** —— 同一个 EC，会互相打架
- ❌ **别在测试时跑重负载** —— 温度拉满会把曲线顶到 100%，观测目标全被冲掉

只读监视工具（可选）：

```powershell
python .\tools\monitor.py --interval 2          # 实时读数
python .\tools\monitor.py --csv monitor.csv     # 顺便存盘
python .\tools\sweep.py                         # 有界负载温度扫描（纯读，超温自动卸载）
```

---

## 出问题怎么办

| 现象 | 原因与处理 |
|---|---|
| 双击 exe 没反应、没窗口 | 正常。GUI 子系统，且需要管理员权限。用第 4 步的重定向方式跑 |
| 启不来，报 DLL 相关错误 | 回第 3 步；若仍失败，说明你的 DLL 哈希不在白名单 → 见门槛 2 |
| `--probe` 读数全是 0 或读不到风扇 | EC 接口不通。**停止**，别尝试写入 |
| 读数与 Control Center 对不上 | **停止一切写入**。EC 语义不符，这份补丁不适用于你的机器 |
| 风扇转速被"拽回"某个值 | 大概率是 `FnKey.exe` 常驻、周期性重申固件自动控制。见 `README.md` 第 8 节 |
| 窗口不弹出来、想开机静默进托盘 | 用 `startup\install-startup.ps1`（可选，与补丁无关） |

---

## 回退（出事就照这个做）

| 情况 | 做法 |
|---|---|
| 想停下控制 | 界面里关闭「软件接管」→ 程序发 `0x69` 交还固件自动（**已实测有效**） |
| 进程死了、风扇卡在某个转速 | **EC 是锁存的，值会一直留着。** 用 **Fn 热键打开 Control Center** 重设风扇，或直接重启 |
| 想还原成官方原版 | 从你留好的官方 zip 重新解压，哈希 `a0032bbf…` 可自证 |
| 想彻底清干净 | `Remove-Item "C:\ProgramData\ClevoFanControl" -Recurse` —— 这是本方案**唯一新增的落盘位置**，删掉即完全还原（WindowsApps 原文件与 ACL 全程未动） |
| 撤掉开机自启 | `schtasks /Delete /TN ClevoFanControl /F` |

> ⚠️ **接管打开后，如果进程崩溃或被强杀，风扇会停在最后写入的占空比上，不会自动交还固件。**
> 回退只有两条路：Fn 热键开 Control Center，或重启。

---

## 一页检查清单

- [ ] 机型字符串含 `P16`
- [ ] FnKey 的 `InsydeDCHU.dll` 哈希 = `75a47020…`（或已知的第二份 `22fecadf…`，风险自负）
- [ ] zip 哈希 = `a0032bbf…`，且已另行备份
- [ ] `apply-patch.ps1 -Verify` 全绿，产物哈希 = `8bc9d401…`
- [ ] `setup-dll.ps1` 报"完成"或"已就绪"
- [ ] `--probe` 读数与 Control Center 逐项一致
- [ ] 配置已改名为 `ClevoFanControl.x64.json` 并放在 exe 同目录
- [ ] 打开接管前，**已经关掉接管观察过一段时间**

---

## 最后

**这不是通用工具，是一台特定机器的适配方案。** 上面的门槛全过，说明你的机器与出方案的那台
在软件层面对得上；但 EC 固件侧的语义（`0xC1` 逐通道命令、`0x69` 位掩码、`to_raw` 换算标定、
缓冲区偏移）**从未被验证过**，接口层齐全 ≠ 语义一致。完整未验证清单见
[`docs/known-risks.md`](docs/known-risks.md) —— **那份文档比本文件更重要，请读一遍。**

风扇控制直接影响散热，**Use at your own risk**。
