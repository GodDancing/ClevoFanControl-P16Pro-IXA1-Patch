# 贡献指南

感谢来看。先说清楚一件事，能省下彼此很多时间：

> **这不是一个通用风扇控制工具，是一台具体机器的适配方案。**
> 它的价值在于「记录得足够细、别人能复核」，而不在于支持更多机器。

所以本仓库**最需要的贡献是实测数据，而不是代码**。请先读
[docs/known-risks.md](docs/known-risks.md) —— 那里列出的每一条未验证项，都是一份可以提交的数据任务。

---

## 一、最需要什么

### 1. 别的机型的实测报告（价值最高）

本方案只在一台 **P16 Pro IXA1** 上验证过，"任何别的机器上的行为 = 零证据"。
如果你的机器**恰好也含 `P16`**（补丁 A 之后的闸门是子串测试，会放行），你的数据能直接回答：
**同一套 EC 语义假设在别的机型上还成立吗？**

最有价值的三种报告：

- **`--probe` 输出与 Control Center 逐项对照** —— 风扇数量、各通道温度、转速是否一致。
  这是验证"缓冲区偏移假设"的唯一途径（`18+i*3` 温度 / `16+i*3` 实际占空比 / `2+i*2` 转速，
  与 [tools/monitor.py](tools/monitor.py) 的 `sample()` 一致）。
- **写入通道映射测试** —— 按 [docs/takeover-test.md](docs/takeover-test.md) 的设计，用两个明显不同的
  占空比（例如 50% / 85%）确认"写下标 → 物理风扇"没有对调。同值写入**无法**暴露对调。
- **`0x69` 恢复固件自动是否有效** —— 关闭接管后占空比是否回落到固件自管水平。

### 2. `docs/known-risks.md` 里未验证项的验证数据

具体包括（照抄自那份文档，欢迎逐条认领）：

- 长时间运行（连续数小时以上）的行为；
- Control Center 与接管互相覆盖时谁赢；
- `FnKey.exe` 常驻对写入手册的干扰；
- `to_raw` 占空比换算的绝对标定（需要转速计或已知满转值）；
- 冷启动以外的热插拔 / 睡眠唤醒路径。

---

## 二、提交实测数据要附什么

**缺一项就没法复核，等于没交。** 请把下面这些一并贴进 issue：

| 项目 | 怎么取 |
|---|---|
| 机型字符串 | `(Get-CimInstance Win32_ComputerSystem).Model` |
| BIOS 版本 | `(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion` |
| Windows 版本 | `winver` 或 `(Get-CimInstance Win32_OperatingSystem).Version` |
| FnKey 组件版本 | `(Get-AppxPackage '*FnhotkeysandOSD*').Version` |
| `InsydeDCHU.dll` 的 SHA256 | `Get-FileHash <FnKey\InsydeDCHU.dll> -Algorithm SHA256` |
| 官方 zip 的 SHA256 | `Get-FileHash <ClevoFanControl-v2.0.0-x64.zip> -Algorithm SHA256` |
| 产物 exe 的 SHA256 | `apply-patch.ps1` 会打印；应为 `8bc9d401…` |

以及：

- **`apply-patch.ps1 -Verify` 的完整输出**（不是"我这边过了"，要原文）；
- **`--probe` 的原始输出**，以及它与 Control Center 是否一致；
- **接管是否已开启**（这一条决定你贴的读数是固件行为还是曲线行为）。

> 数据贴进 issue 即可。**不要把 exe / dll / zip 当附件传上来**（见下一节）。

---

## 三、明确**不接受**的

### 1. 任何 exe / dll / 二进制 PR 或附件

上游仓库**没有 LICENSE**，默认保留所有权利；厂商 DLL 属专有组件。
本仓库只分发自己写的补丁脚本与文档，**理由与法律依据见 [NOTICE.md](NOTICE.md)**。
PR 里附二进制会被直接拒绝，这不是偏好问题，是许可问题。

### 2. 任何厂商组件的再分发

`InsydeDCHU.dll` / `AcpiBridge.sys` 属蓝天 / Insyde 所有。`patch/setup-dll.ps1` 只在**本机**
把它们复制到程序能加载的位置，**不修改原文件、不改 ACL、不外传**。任何"把这几个文件打包进来方便大家用"
的改动都不接受。

### 3. 源码层之外的"绕过机型闸门"通用化改动

**本仓库刻意只针对一台机器。** 任何试图把补丁做成"支持任意机型 / 加个 `-AnyModel` 就放行"的
通用化改动都会被拒绝 —— 补丁 A 之所以能拆掉闸门，是因为出方案的人**对这台机器的风险有判断**；
把它通用化等于把未经检验的 EC 语义假设强加给别人的机器。真正通用的方向是**改上游源码**
（`hardware.rs` 的机型闸门 + `platform.rs::find_dll()` 的兜底），那样才能跟上游同步。

### 4. 其余不收的

- CI workflow —— 本项目没有 CI，也不需要（没有构建、没有可自动跑的测试）。
- 新的一套等价安装脚本（例如 POSIX shell 版）—— 本仓库是 **Windows 专用**，
  CANONICAL 入口是已存在的 `install.bat`；再加一种语言维护同一套逻辑必然漂移。
- 依赖 / 包管理清单 —— 没有构建步骤。

**一句话判据：能帮别人"复核这份记录是否属实"的贡献欢迎；帮人"更省事地绕过验证"的不欢迎。**

---

## 四、如果只是报告问题

**请先读 [docs/known-risks.md](docs/known-risks.md)。** 那份文档已经写明了大量"已知就是这样、
不是 bug"的行为 —— 例如 EC 锁存、固件占空比不是温度的纯函数、"和 Control Center 对得上只是快照不是标定"。

确实要报，请用 issue 模板（`.github/ISSUE_TEMPLATE/bug_report.md`）并尽量填全表单字段。
缺信息的报告会先被搁置──没有机型 / 哈希 / 原始输出，无法判断是你那边的问题还是本方案的假设不成立。

## 五、许可

你的贡献（文档、脚本改动、实测数据）按本仓库的 [LICENSE](LICENSE)（MIT）授权，
覆盖范围与 [NOTICE.md](NOTICE.md) 所述一致。**不要提交你自己无权授权的内容。**
