# ClevoFanControl-P16Pro-IXA1-Patch

面向 AI 编码助手的项目速览。人读的完整流程见 [QUICKSTART.md](QUICKSTART.md)，风险清单见
[docs/known-risks.md](docs/known-risks.md)（**最重要的一篇**）。

## 这是什么 / 不是什么

**是**：一台具体机器（蓝天 Clevo **P16 Pro IXA1**）的适配方案 + 一份可复核、可复现的逆向记录。

**不是**：通用风扇控制工具、上游 [`XiaoQing235/ClevoFanControl`](https://github.com/XiaoQing235/ClevoFanControl)
的分支、或任何"支持多机型"的东西。**本仓库刻意只针对一台机器**。

它对上游 **v2.0.0 官方 release 二进制**施加 3 处按绝对文件偏移的字节补丁，让程序在本机能跑。**不含源码改动、不重新编译、不含任何二进制、不含厂商 DLL。**
全仓库没有构建步骤、没有 CI、没有测试框架 —— 交付物就是脚本 + 文档 + 测量数据。

## 常用命令

全部在 **PowerShell** 里执行；除最后运行程序外都不需要管理员权限。

```powershell
# 一键入口（也是 CANONICAL 的入口；本仓库是 Windows 专用，没有 setup.sh）
.\install.bat                      # 双击亦可；会询问官方 zip 路径

# 手动等价流程
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1 -Zip <zip> -Verify  # 空转校验，不写产物
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\apply-patch.ps1 -Zip <zip>          # 正式打补丁
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch\setup-dll.ps1                       # 铺厂商 DLL 副本

# 只读验证（GUI 子系统，必须重定向才能拿到输出）
$p = Start-Process .\clevo-fan-control.exe -ArgumentList "--probe" -Wait -PassThru `
     -RedirectStandardOutput "$env:TEMP\probe.out" -RedirectStandardError "$env:TEMP\probe.err"
"exit=$($p.ExitCode)"; Get-Content "$env:TEMP\probe.out","$env:TEMP\probe.err"

# 只读监视 / 有界负载扫描
python .\tools\monitor.py --interval 2 [--csv m.csv]
python .\tools\sweep.py

# 可选：登录静默进托盘（与补丁独立）
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\install-startup.ps1 -Mode Show
```

## 架构与关键文件

```text
install.bat            纯 ASCII 启动器（中文字符串一律放在 install.ps1）
install.ps1            一键安装逻辑：-Verify → 打补丁 → 铺 DLL → 放配置 →（可选）--probe
patch/apply-patch.ps1  ★ 补丁器本体：6 道校验 + 3 处就地字节覆盖
patch/setup-dll.ps1    从本机 FnKey/CC 包复制 DLL 到 C:\ProgramData\ClevoFanControl\
docs/patch-notes.md    ★ 补丁的权威逐字节记录（偏移、机器码、哈希）
docs/known-risks.md    ★ 未验证项完整清单
docs/curve.md          曲线与调参
docs/takeover-test.md  写入通道映射验证的设计与判定表
docs/startup.md        开机自启机制全套
docs/data/*.csv        原始测量数据；docs/probe-output.txt 为 --probe 实测输出
tools/monitor.py       只读监视（0x0D / 0x0C，绝不 SetDCHU）
tools/sweep.py         有界负载温度扫描（纯读，超温自动卸载）
startup/*.ps1          登录时把窗口收进托盘的启动器与计划任务安装器
```

数据流：`apply-patch.ps1` 读取**用户自行下载**的官方 zip → 校验 zip/exe 哈希 → 在内存里改 3 处字节 → 校验产物哈希 → 写出 `patch\build\clevo-fan-control.exe`。程序运行时通过 `setup-dll.ps1` 铺好的 DLL 副本访问 EC；仓库自身从不接触 EC。

## 改代码时必须知道的硬约束

1. **三处补丁按绝对文件偏移定位**，只对 v2.0.0 这一个构建有效：
   - A `0x1959C0` 5 字节：`NP5SN` → `P16P1`（机型闸门 `contains("P16")`）
   - B `0x195174` 3 字节：`dll` → `bak`（让 Appx 分支 `is_file()` 落空）
   - C `0x1951D8` 51 字节：兜底 DLL 路径改指 `C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll`
2. **补丁 C 的替换路径必须仍是 51 字节，且 `.dll` 必须落在偏移 47。** Rust 做了常量折叠：前 48 字节由 SSE 从 `.rdata` 拷走，最后 4 字节 `MOV dword [rax+0x2f], 0x6c6c642e` 是运行时立即数、不在 `.rdata` 里。`apply-patch.ps1` 第 5 步会模拟这个拼接并校验。
3. **校验必须逐字节比对完整的字面量，不能只比"变化的字节"。** 补丁 C 两条路径意外共享了 `C:\Program`、`Control`、`.dll`，51 字节里只有 29 字节真的不同（总变化 37 = 5+3+29）。只比变化区间等于自废校验。
4. **产物哈希是决定性的**：`8BC9D40104BABF90BC2AAA0C987424EB7EC5B3A25173A0D8FBC49F837C559A69`；原始 exe `9DB6D1E3…`；原始 zip `A0032BBF…`。改任何一个常量都意味着这份适配变了，**必须同步更新 `docs/patch-notes.md`**。
5. **exe 内置的 DLL 白名单只有两个 SHA256**：`75A47020…`（FnKey 包，已验证）与 `22FECADF…`（另一份，本仓库未验证）。对应 `hardware.rs:52-56`。
6. **绝不可提交任何二进制或厂商 DLL。** `.gitignore` 已挡 `*.exe *.dll *.sys *.zip *.msi build/`；`*_REPORT*.md` 与流水线报告也不入库。违反这条会直接触碰上游与厂商的许可问题（见 [NOTICE.md](NOTICE.md)）。

## 编码约定

- **含中文的 `.ps1` 必须 UTF-8 with BOM + CRLF**（仓库内 `install.ps1`、`patch/apply-patch.ps1`、`patch/setup-dll.ps1` 均已如此）。缺 BOM 会让 Windows PowerShell 5.1 按本地代码页解释中文而乱码。
- `startup/*.ps1` 目前是**纯 ASCII（无 BOM，可接受）**；若将来往里面加中文，**必须补上 BOM**，否则会乱码。
- **`install.bat` 必须无 BOM + CRLF + 零非 ASCII 字节** —— 它的启动器注释里写明了这一点，纯 ASCII 是为了不受控制台代码页影响。
- Markdown / YAML / JSON / CSV / TXT 用 **UTF-8 无 BOM + LF**（`.gitattributes` 已声明；不要违反）。
- 需要中文提示时，放进 `.ps1`，不要放进 `.bat`。

## 安全红线（改任何东西前先读）

- **不要运行 `--hardware-check`** —— 它会真的改变风扇占空比，不是普通测试命令。
- **不要按界面里的「强制冷却」** —— 写入闸门是 `cfg.take_over || force`，**接管关着它也会往所有通道写 95%**。这是最容易误触的一条。
- **`forceTemp: 50` 是退出阈值，不是安全阀**；上游内置默认曲线是 45–90 °C 全部 40% 的平直线，**不要用**。
- **EC 是锁存的**：接管打开后进程崩溃/被强杀，风扇会停在最后写入的占空比上，不会自动交还固件。回退只有 Fn 热键开 Control Center 或重启两条路，**不要**设计成"进程守护能兜底"。
- `--probe` 是**只读采样**，安全；`tools/*.py` 也从不调用 `SetDCHU_Data`。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。最需要的是**别的机型的实测数据**，不是代码改动。
