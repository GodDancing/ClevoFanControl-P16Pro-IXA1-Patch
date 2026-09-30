# clevofancontrol-p16pro

面向 **蓝天 Clevo P16 Pro IXA1** 的 ClevoFanControl 适配补丁。

做法是对上游 [`XiaoQing235/ClevoFanControl`](https://github.com/XiaoQing235/ClevoFanControl) **v2.0.0 官方 release 二进制**施加 3 处按偏移的字节补丁，让它在 P16 Pro IXA1 上能够运行。**不是源码改动，没有重新编译。**

> **本仓库不含任何二进制。** 没有上游的 exe、没有厂商 DLL、没有预编译产物。
> 只有补丁脚本、逆向记录、测量数据和只读诊断工具。原因见 [NOTICE.md](NOTICE.md)。

> **第一次用、只想照着做？** 看 **[QUICKSTART.md](QUICKSTART.md)** —— 从两道硬门槛自检、
> 确认官方 zip 路径，到打补丁、铺 DLL、只读验证、启用接管，含排错表与完整回退路径。

---

## 1. 这是什么 / 不是什么

**是**：一台具体机器（P16 Pro IXA1）的适配方案，以及一份可复核、可复现的逆向记录。

**不是**：通用风扇控制工具；不是上游的分支；不保证任何其他机型可用。

上游 v2.0.0 在本机跑不起来有**两个独立原因**：

1. `hardware.rs:37` 硬编码机型闸门，只认 `NP5x_6x_7x_SNx`；
2. 它加载厂商 DLL 的首选路径落在 `WindowsApps` 下，而该目录给 `Users` 只有 `Read`、没有 `FILE_EXECUTE`，`LoadLibraryExW` 一律返回 `ERROR_ACCESS_DENIED(5)`。

3 处补丁分别绕开这两点。逐字节细节见 [docs/patch-notes.md](docs/patch-notes.md)。

---

## 2. ⚠️ 适用范围与风险 —— 请先读这一节

- **只在一台机器上验证过**：蓝天 P16 Pro IXA1（SMBIOS Model = `P16 Pro IXA1`，BIOS `1.07.10COLO`，Windows 11 Pro for Workstations 10.0.26100，x64）。
- **补丁 A 把机型闸门换成了一个子串测试。** 上游判据是 `machine.contains("NP5") && machine.contains("SN")`，补丁后是 `machine.contains("P16")`。**这不是白名单** —— 任何 SMBIOS 字符串里恰好嵌了 `P16` 的机器都会放行。而作者设这道闸门的原因，恰恰是**他自己也无法静态确认 EC 固件侧的语义**。拆掉它，等于把这个风险转移到使用者身上。
- **EC 固件侧的语义完全没有验证。** 接口层齐全（`_DSM` UUID、`PK04`/`ECMD`、`ACPI\CLV0001`）**不等于**语义一致 —— 接口普遍存在、语义各自不同，这正是陷阱本身。完整清单见 [docs/known-risks.md](docs/known-risks.md)。
- **EC 是锁存的，不需要保活刷新。** 接管打开后如果进程崩溃 / 被强杀，风扇会停在最后写入的那个占空比上，**不会自动交还固件**。
- **回退只有两条路**：Fn 热键打开 Control Center 重设风扇，或直接重启。

**如果你不是 P16 Pro IXA1 用户，请不要使用本补丁。**
`patch/apply-patch.ps1` 会先检查机型，不符时直接拒绝运行（`-Force` 可跳过，但那是自己承担风险）。

风扇控制直接影响散热，**Use at your own risk**。

---

## 3. 已验证 / 未验证

### 3.1 已实测（本机，有数据）

| 结论 | 证据 |
|---|---|
| 读取路径可用 | `--probe` 退出码 0，2 个通道，输出留档于 [docs/probe-output.txt](docs/probe-output.txt) |
| **写入通道映射同序、无对调** | 差异化写入（ch1 目标 50%、ch2 目标 85%）：两通道各自升到**恰好** 50% / 85%，且转速**各自分开动**（ch1 3213→4253 rpm，ch2 2122→6161 rpm）。同值写入无法暴露对调，所以刻意用了两个明显不同的目标值 |
| `0x69` 恢复固件自动**有效** | 关闭接管后占空比回落到固件自管水平 |
| EC **锁存**，无需保活 | 程序停止写入后 50% / 85% 稳定保持 **36 秒** |
| 读取稳定 | 255 次采样 0 失败 |
| 冷启动全路径 | 用户重启后确认：登录时窗口一闪即收进托盘，托盘有图标，接管正常 |

原始数据在 [docs/data/](docs/data/)：`takeover-test.csv`（513 行）、`sweep.csv`、`sweep-smoke.csv`。

### 3.2 完全未验证 ← **风险的真正所在**

- **`PK04` 背后 EC 固件侧的语义**：`0xC1` 逐通道命令、`0x69` 恢复自动的位掩码、`to_raw` 占空比换算的**绝对标定**、缓冲区偏移（`18+i*3` 温度 / `16+i*3` 实际占空比 / `2+i*2` 转速）。这些在 EC 固件里，静态分析无法确认。
- **任何别的机器上的行为** —— 零证据。
- **「50 就是物理最大转速的 50%」** —— 没有转速计，也没有已知满转值，无法验证。
- **长时间运行** —— 从未连续运行超过数小时。
- **Control Center 与接管的互相覆盖** —— 未测。
- **`FnKey.exe` 的干扰** —— 未测（它一直在运行）。

### 3.3 一个已知的数据冲突（值得警惕）

| 来源 | ch2 读数 |
|---|---|
| `docs/takeover-test.md` 记的基线 | 61 °C / **24%** / 2122 rpm |
| [docs/probe-output.txt](docs/probe-output.txt) | 61 °C / **43%** / 3570 rpm |

同一温度、占空比差近一倍 ⇒ **固件占空比不是温度的纯函数**，`FnKey.exe` / Control Center 也在写同一块 EC。
所以「和 Control Center 对得上」只是**同一时刻的一致性快照，不是标定**。

---

## 4. 前置条件

1. **同型号机器**：蓝天 P16 Pro IXA1（补丁 A 之后的判据是 SMBIOS 字符串含 `P16`）。
2. **同一份 FnKey 组件**。程序卡的是 **DLL 哈希**，不是机型字符串：

   | 情况 | DLL 哈希 | 结果 |
   |---|---|---|
   | 同型号 + FnKey `7.62.3.0` | `75a47020…` | 通（**本仓库验证过的情况**） |
   | 同型号 + FnKey 版本不同 | 可能变成别的哈希 | **不在程序白名单 → 程序直接拒绝加载**，与补丁无关 |

3. **官方 zip 原件**：`ClevoFanControl-v2.0.0-x64.zip`，
   SHA256 `a0032bbfdc2aa85ec24cd6c449ec386a548b1b00648511ae18c43345912cb1ac`
   （下载地址见 `patch/apply-patch.ps1` 里的 `$UPSTREAM_URL`）。
   **这份 zip 请自己留好** —— 它是回退的唯一来源，也是重新打补丁的唯一输入。
4. **管理员权限**（exe 的 manifest 是 `requireAdministrator`）、Microsoft Visual C++ x64 运行库。

---

## 5. 安装步骤

### 5.0 一键安装（推荐）

双击仓库根目录的 **`install.bat`** 即可。它会依次：

1. 询问官方 zip 的完整路径 —— **不搜索硬盘，只认你给出的路径**
2. 空转校验（`apply-patch.ps1 -Verify`，不写出产物；只在 `%TEMP%` 下临时解包，退出时清理）
3. 正式打补丁 → `patch\build\clevo-fan-control.exe`
4. 铺设厂商 DLL
5. 放置示例配置（**仅当目标不存在时**，不会覆盖你调好的那份）
6. 若以管理员身份运行，可选立即做只读验证（`--probe`）

任一环节失败即**中止，不产出半成品**。也可以把 zip 文件直接拖到 `install.bat` 上。

> `.bat` 是纯 ASCII 的启动器，所有中文提示都在 `install.ps1` 里 —— 这样不受控制台代码页
> 影响，不会出现乱码。`install.ps1` 自身同样不发任何硬件命令。

### 5.1 手动执行（等价流程）

全程在 **PowerShell** 里执行。

```powershell
# 1. 从官方 zip 重建已适配的 exe（6 道校验，任一失败即中止，不产出半成品）
#    先空转确认能过：
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1 -Verify
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1
#    产物：patch\build\clevo-fan-control.exe，SHA256 应为 8bc9d401…

# 2. 铺厂商 DLL（程序唯一的外部依赖；只做复制，不碰 EC）
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\setup-dll.ps1
#    目标 C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll

# 3. 把产物和配置放到同一个可写目录，然后做只读验证（见第 6 节）
```

`apply-patch.ps1` 的 6 道校验依次是：机型含 `P16` → zip 的 SHA256 → zip 内 exe 的 SHA256 → 三个偏移处的**完整**原始字面量 → 补丁 C 的运行时拼接结果 → **产物 SHA256**。
最后一条是关键：它把「补丁逻辑对不对」变成一个可判定的字节级等式。

> **补丁必须校验完整的字面量，不能只比「变化的字节」。** 补丁 C 的两条路径意外共享了开头的 `C:\Program`、中间的 `Control` 和结尾的 `.dll`，51 字节里只有 29 个字节真的不同（所以总变化量是 37 = 5 + 3 + 29，不是 59）。只比变化区间等于自废校验。

**关于配置**：配置文件名固定为 `ClevoFanControl.x64.json`，**放在 exe 同目录就会被自动加载**（缺了则退回内置默认值，`take_over` 变回 `false`，等于完全不管风扇）。
本仓库只提供 [ClevoFanControl.x64.example.json](ClevoFanControl.x64.example.json) —— 文件名不同，**不会被自动加载**，请自行改名后使用，并注意它刻意写成 `takeOver: false` + `autoRun: false`。

---

## 6. 只读验证怎么做

Release 版是 **GUI 子系统**（`Subsystem=2`），**没有控制台**：直接双击或从命令行运行都不会有任何输出，而且 shell 不会等它。要拿到输出必须重定向：

```powershell
$p = Start-Process -FilePath ".\clevo-fan-control.exe" -ArgumentList "--probe" -Wait -PassThru `
     -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"
"exit=$($p.ExitCode)"
Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"
```

然后**按这个顺序**推进：

1. 先跑 `--probe`（**只读采样，不写 EC**），核对风扇数量、各通道温度、转速与 Control Center 是否逐项一致。
   若报 `DLL 版本尚未验证：C:\ProgramData\…` → 说明路径补丁生效了，只是 DLL 副本没放对（回第 5 节第 2 步）。
2. 一致后打开界面，**保持「软件接管」关闭**，只观察。
3. 确认无误再启用接管。曲线务必按本机散热能力调（[docs/curve.md](docs/curve.md)）。
4. **不要**一上来就跑 `--hardware-check` —— 它会真的改变风扇占空比，不属于普通测试命令。
5. 若第 1 步读数与 Control Center 不一致，**立即停止一切写入**。

只读监视工具：`tools/monitor.py`（`--interval`、`--csv`）、`tools/sweep.py`（有界负载温度扫描，纯读、超温自动卸载）。

---

## 7. 回退

| 情况 | 做法 |
|---|---|
| 想停下 | 界面里关闭「软件接管」→ 程序发 `0x69` 交还固件自动（**已实测有效**） |
| 进程死了、占空比锁在风扇上 | EC 是锁存的，值会一直留着。用 **Fn 热键打开 Control Center** 重设，或重启 |
| 恢复出厂 exe | 从官方 zip `ClevoFanControl-v2.0.0-x64.zip` 重新解压（原始包未改动，哈希 `a0032bbf…` 可自证） |
| 撤掉 DLL 副本 | `Remove-Item "C:\ProgramData\ClevoFanControl" -Recurse`。该目录是本方案**唯一新增的落盘位置**，删掉即完全还原（WindowsApps 原文件与 ACL 全程未动） |
| 撤掉开机自启 | `schtasks /Delete /TN ClevoFanControl /F`（若在界面里开过自启） |

---

## 8. 已知干扰源

- **`FnKey.exe` 常驻**，也用同一份 `InsydeDCHU.dll`，可能周期性重申固件自动控制 ⇒ 表现为占空比被「拽回」固件值。
- **Control Center** 会自己写风扇曲线，与接管互相覆盖。本机没有独立安装的 CC，但 FnKey 包里捆了 CC40，可由 Fn 热键打开。谁赢未测。
- 别在测试期间跑重负载：温度过高会让曲线拉满，把观测目标冲掉。

另外两条容易误触的：

- **「强制冷却」按下去会往所有通道写 95%，即使接管是关的** —— 写入闸门是 `cfg.take_over || force`。这是最容易误触的一条。
- **`forceTemp: 50` 是它的退出阈值，不是安全阀。**
- **上游内置的默认曲线是 45–90 °C 全部 40% 的平直线**，接管一开就是把两风扇钉在约 40%，到 90 °C 也不升。**不要用。**

---

## 9. 路径说明（文档里的相对路径）

本仓库里的文档是从工作目录原样搬过来的，文中提到的脚本名对应关系如下：

| 文档里写的 | 本仓库位置 |
|---|---|
| `apply-patch.ps1` | [patch/apply-patch.ps1](patch/apply-patch.ps1) |
| `setup-dll.ps1` | [patch/setup-dll.ps1](patch/setup-dll.ps1) |
| `start-hidden.ps1` / `install-startup.ps1` | [startup/](startup/) —— 属「开机自启不弹窗」，与补丁本身是**两件独立的事**，可不使用 |
| `monitor.py` / `sweep.py` | [tools/](tools/) |
| `PATCH-NOTES.md` | [docs/patch-notes.md](docs/patch-notes.md) |
| `*.csv` | [docs/data/](docs/data/) |

另外，`docs/*.md` 里出现的**绝对路径**（例如 `%USERPROFILE%\Downloads\ClevoFanControl-v2.0.0-p16pro\`）反映的是作者当时的目录布局，**与你的布局未必相同** —— 请按你实际放置 exe / 仓库的位置换算。本 README 与 [QUICKSTART.md](QUICKSTART.md) 用的是相对本仓库的路径。

---

## 10. 许可与致谢

- **本仓库不含上游的二进制，也不含厂商 DLL。** 完整说明见 [NOTICE.md](NOTICE.md)。
- 上游仓库根目录**没有 LICENSE 文件**，即默认「保留所有权利」。因此本仓库**只分发自己写的补丁脚本与文档**，不包含任何形式的修改后二进制。这是刻意的选择，不是疏漏。
- 厂商组件 `InsydeDCHU.dll` / `AcpiBridge.sys` 属蓝天 / Insyde 的专有软件，由官方 Control Center / FnKey 包安装。`patch/setup-dll.ps1` 只在**本机**把它们复制到程序能加载的位置，**不修改原文件、不修改任何 ACL、不外传**。
- 本仓库的 [LICENSE](LICENSE) 仅覆盖本仓库作者自己撰写的代码与文档。
- 想参与或者提交自己机型的实测数据，见 **[CONTRIBUTING.md](CONTRIBUTING.md)** —— 本仓库最需要的贡献是**别的机型的实测报告**，不是代码改动；同时那里也写明了**不接受**哪些 PR（任何二进制、厂商组件再分发、把机型闸门通用化）。
- 致谢上游作者与原作者们：
  [`XiaoQing235/ClevoFanControl`](https://github.com/XiaoQing235/ClevoFanControl)（当前实现，Rust + FLTK）、
  [`wangsihan158/myfancontrol`](https://github.com/wangsihan158/myfancontrol)、
  [`xl-Synapse/MyFanControl`](https://github.com/xl-Synapse/MyFanControl)、
  [`zuyan9/RLECViewer`](https://github.com/zuyan9/RLECViewer)。

---

## 11. 上游更新了怎么办

**不要在新版上游 release 上套这三个偏移。**

补丁全部按**绝对文件偏移**定位（`0x1959c0` / `0x195174` / `0x1951d8`），只对 v2.0.0 这一个确定的构建有效。上游一发新版，偏移必然失效 —— `apply-patch.ps1` 会在「zip 内 exe 哈希」这一步就拒绝运行，这是**预期行为**。

正确的长期方向是改**源码**（`hardware.rs` 的机型闸门 + `platform.rs::find_dll()` 的兜底），那样才能跟上游同步，而且顺带绕开整个再分发问题。本机当时没有 Rust 工具链，所以走了字节补丁这条路。

---

## 仓库结构

```text
.
├── README.md                          本文件
├── QUICKSTART.md                      从零开始的完整操作流程 ← 第一次用先读这个
├── install.bat                        一键安装入口（双击即可；纯 ASCII 启动器）
├── install.ps1                        一键安装的实际逻辑（中文提示都在这里）
├── CLAUDE.md / AGENTS.md              面向 AI 编码助手的项目说明（含改代码时的硬约束）
├── CONTRIBUTING.md                    贡献指南 ← 最需要的是别的机型的实测数据
├── LICENSE                            只覆盖本仓库作者的代码与文档
├── NOTICE.md                          不含上游二进制与厂商 DLL 的声明及原因
├── .gitignore / .gitattributes        二进制不入库 / 行尾与编码规则
├── ClevoFanControl.x64.example.json   安全示例配置（takeOver 与 autoRun 均为 false）
├── .github/ISSUE_TEMPLATE/            报问题用的表单（会问机型 / DLL 哈希 / --probe 输出）
├── patch/
│   ├── apply-patch.ps1                从官方 zip 重建适配版 exe（6 道校验）
│   └── setup-dll.ps1                  铺设厂商 DLL 副本
├── startup/                           可选：登录时静默进托盘（与补丁独立）
│   ├── start-hidden.ps1
│   └── install-startup.ps1
├── tools/
│   ├── monitor.py                     只读监视
│   └── sweep.py                       有界负载温度扫描（纯读）
└── docs/
    ├── patch-notes.md                 补丁的权威记录（逐字节）
    ├── known-risks.md                 未验证项的完整说明 ← 最重要
    ├── curve.md                       曲线与调参
    ├── takeover-test.md               接管映射验证的设计与判定表
    ├── startup.md                     开机自启全套
    ├── probe-output.txt               --probe 的实测输出
    └── data/                          原始测试数据（CSV）
```
