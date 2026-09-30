---
name: Bug report / 问题报告
about: 报告本方案在你的机器上不工作，或与文档描述不符
title: "[bug] "
labels: bug
---

<!--
  提交前请先读 docs/known-risks.md。那里列出的很多行为是"已知就是这样"，
  不是 bug（例如 EC 锁存、固件占空比不是温度的纯函数）。

  缺信息无法定位问题。请尽量填全下面每一项 —— 尤其是哈希与原始输出。
  请勿上传 exe / dll / zip 等任何二进制（见 NOTICE.md）。
-->

## 一句话描述

<!-- 发生了什么，你期望发生什么 -->

## 机型与环境（必填）

- **机型字符串**（`(Get-CimInstance Win32_ComputerSystem).Model`）：
- **BIOS 版本**（`(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion`）：
- **Windows 版本**（`winver` 或 `(Get-CimInstance Win32_OperatingSystem).Version`）：
- **FnKey 组件版本**（`(Get-AppxPackage '*FnhotkeysandOSD*').Version`）：
- **`InsydeDCHU.dll` 的 SHA256**（`Get-FileHash <FnKey\InsydeDCHU.dll> -Algorithm SHA256`）：

> 只有机型含 `P16`（例如 `P16 Pro IXA1`）且 DLL 哈希在白名单内，本方案才适用。
> 若你的机器不是 P16 Pro IXA1，请先说明 —— 很可能是不适用，而不是 bug。

## 哈希核对（必填）

- **官方 zip 的 SHA256**：应等于 `A0032BBFDC2AA85EC24CD6C449EC386A548B1B00648511AE18C43345912CB1AC`
- **产物 exe 的 SHA256**：应等于 `8BC9D40104BABF90BC2AAA0C987424EB7EC5B3A25173A0D8FBC49F837C559A69`

## 复现步骤

1.
2.
3.

## `patch\apply-patch.ps1 -Verify` 的完整输出

<!-- 原文粘贴，不要只写"过了"或"没过" -->

```text

```

## `--probe` 的输出

<!-- 原文粘贴（stdout + stderr + exit code） -->

```text

```

## `--probe` 的读数与 Control Center 是否一致？

- [ ] 风扇数量一致
- [ ] 各通道温度一致
- [ ] 转速一致
- [ ] 不一致（请具体说明哪一项、差多少）

<!-- 若不一致：这是本方案最关键的失效信号，请把两边读数逐项列出 -->

## 接管是否已开启？

- [ ] 接管**关闭**（读数应为固件行为）
- [ ] 接管**开启**（读数应为曲线行为）

## 补充信息

- 是否跑过 `--hardware-check`？（**不推荐**，它会真的改占空比）
- 是否按过界面里的「强制冷却」？
- `FnKey.exe` / Control Center 当时是否在运行？
- 其他你认为相关的现象：
