# 开机自启不弹窗（收进托盘）

目标：登录时 ClevoFanControl 照常启动并接管风扇，但**主窗口不出现**，直接进托盘。

不重新编译，也不改程序二进制。

## 为什么不能走别的路

| 路 | 为什么不通 |
|---|---|
| 配置文件加字段 | 结构体是 `deny_unknown_fields`，多一个键**整个配置加载失败**，反而丢掉你的曲线 |
| 程序自带的开关 | 没有。`src/main.rs` 只认 `--demo` / `--smoke` / `--probe` / `--hardware-check` |
| 重新编译 | 本机没装 Rust 工具链，还要拉 FLTK/CMake 一整条依赖 |

## 机制：借程序自己的「关闭时隐藏到托盘」

程序启动时**无条件** `win.show()`，所以窗口一定会出现；但它同时**无条件**创建托盘图标，
并且已经把窗口的关闭回调接到了 `Action::Close`。于是「启动后立刻给它发一条 `WM_CLOSE`」
＝ 替你点了一下右上角的 ×，程序自己走 `win.hide()`，窗口收进托盘，进程和风扇 worker 继续跑。

源码依据（v2.0.0）：

| 事实 | 位置 |
|---|---|
| 启动时无条件显示主窗 | `src/ui.rs:937` `win.show()` |
| 启动时无条件建托盘 | `src/ui.rs:940` `Tray::start(...)` |
| 关闭回波接线 | `src/ui.rs:794` `win.set_callback(move \|_\| tx.send(Action::Close))` |
| 关闭时隐藏到托盘 | `src/ui.rs:1464` `Action::Close if fields.close.value() && tray.is_some() => win.hide()` |
| 勾选项语义 | `src/ui.rs:839` 「关闭时隐藏到托盘」= `close_to_tray` |
| 托盘能找回窗口 | 左键 → `NativeEvent::Show`；右键菜单「显示 / 隐藏 / 退出」 |

**只用 `WM_CLOSE`，从不杀进程、从不销毁窗口。** worker 线程持续运行，EC 不会失去管理。

### 一个必须避开的坑

托盘图标自己的窗口是 `CreateWindowExW(..., dwStyle = 0, ...)`，**不可见**；但它的 `WM_CLOSE`
是 `NIM_DELETE` + `DestroyWindow`（`src/platform.rs`），**把托盘干掉就再也收不了窗**。
所以脚本只对「可见 + 顶层 + 有标题 + 类名不是 `ClevoFanControl.Tray.x64`」的窗口发消息。
实测枚举结果：

```
hwnd=0x30D52 class=FLTK                        visible top-level  ← 选它
hwnd=0x30D64 class=ClevoFanControl.Tray.x64    hidden  top-level  ← 排除
hwnd=0x40D46 class=GDI+ Hook Window Class      hidden  top-level  ← 排除
hwnd=0x30D4C class=MSCTFIME UI                 hidden  owned      ← 排除
```

### 必须提权

程序 manifest 是 `requireAdministrator`，而 **UIPI** 会把低完整性进程发往高完整性窗口的消息
直接丢掉。同一个脚本、同一个窗口：

| 运行身份 | 结果 |
|---|---|
| 非提权 | `WM_CLOSE -> refused (win32 error 5)` —— 消息被丢，窗口纹丝不动 |
| 提权 | `WM_CLOSE -> ok` —— 窗口随即消失，进程存活 |

计划任务是 `RunLevel=HighestAvailable`，天然满足。脚本里有提权自检，没提权直接**报错退出**，
不会静默失败。

## 目录布局（2026-09-27 搬家后）

工具在 **`<安装目录>\`**，只放跑起来要用的：`clevo-fan-control.exe`、
`ClevoFanControl.x64.json`（配置，**不能挪** —— 程序从 exe 同目录读它，缺了就退回默认值，
`take_over` 变回 false，等于风扇完全不管）、`start-hidden.ps1`、`install-startup.ps1`、
`setup-dll.ps1`、`licenses/`、`THIRD_PARTY_NOTICES.md`。

文档、测量工具（`monitor.py` / `sweep.py`）、测试数据（`*.csv`）、本文件和日志都在隔壁
**`<工作目录>\`**。

计划任务的动作里存的是**绝对路径**，所以搬目录不会自动跟着走：在**新位置**重跑一次
`install-startup.ps1 -Mode Install` 就会重新指向（`-Exe` / `-Launcher` 默认取脚本自身所在目录，
因此脚本本身是位置无关的）。

## 文件

| 文件 | 现在在 | 作用 |
|---|---|---|
| `startup/start-hidden.ps1` | `startup\` | 启动器：拉起程序 → 等主窗 → 发 `WM_CLOSE` → 校验结果。也支持 `-DryRun` / `-Diagnose` |
| `startup/install-startup.ps1` | `startup\` | 把计划任务改指向启动器 / 还原 / 查看 / 自检 |
| `patch/setup-dll.ps1` | `patch\` | 从 WindowsApps 重铺 `ProgramData` 下那个 DLL（程序唯一的外部依赖） |
| `start-hidden.log`（运行后生成） | `startup\` | 每次运行追加一行结果（含提权状态与 `PostMessage` 返回值） |

下方命令里的脚本路径都相对**仓库根目录**而言。

启动器**不会**启动第二个实例（单实例互斥会让第二次启动弹错误框就退），
发现已有实例时只处理它现有的窗口。

## 用法

四条命令，都要在**提权**的 PowerShell 里跑：

```powershell
# 改指向启动器（本机已执行过，当前生效）
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\install-startup.ps1 -Mode Install

# 看现在指向谁
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\install-startup.ps1 -Mode Show

# 立刻跑一次任务并打印启动器的日志
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\install-startup.ps1 -Mode Test

# 还原成原来那样（窗口照旧在登录时弹出）
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\install-startup.ps1 -Mode Restore
```

非提权也能用的两个诊断（只读，不发消息）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\start-hidden.ps1 -DryRun    # 找出目标窗口，不发
powershell -NoProfile -ExecutionPolicy Bypass -File .\startup\start-hidden.ps1 -Diagnose  # 列出该进程所有顶层窗口
```

## 已验证 / 未验证

**已实测（2026-09-27）**

- 窗口定位：只选中 `class=FLTK` 主窗，托盘窗 / GDI+ 钩子窗 / IME 窗全部正确排除。
- 提权下 `WM_CLOSE -> ok`，窗口从枚举列表消失，`ClevoFanControl.Tray.x64` 仍在，进程存活。
- 非提权下 `refused (win32 error 5)`，窗口不动 —— UIPI 行为与预期一致。
- 计划任务改指向后，`LogonTrigger` / `HighestAvailable` / `S-1-5-32-545` /
  `MultipleInstancesPolicy` / `ExecutionTimeLimit` 全部保留。
- `schtasks /Run` 触发任务 → 启动器被提权拉起 → 日志有记录。
- **冷启动整条路径（用户重启后确认）**：登录后窗口一闪即收进托盘，托盘有图标，风扇接管正常。
  这是全路径的最终验收。

**未验证**

- 无。

`start-hidden.log` 里一次正常冷启动应是：
`started: ...` → `found ...` → `WM_CLOSE -> ok` → `OK  window hidden, process still running`。

### 「零闪烁」试过了，不行（2026-09-27 实测）

启动器最初用 `Start-Process -WindowStyle Hidden` 起程序，指望窗口连闪都不闪。去掉了。

**实测结果：窗口确实一次都没出现过（真零闪烁），但之后从托盘点「显示」再也弹不出窗口。**
不是 FLTK 记错了状态 —— 是 FLTK 的 win32 后端在 `fl_open_display()` 里把 `STARTUPINFO`
的 `nCmdShow` 缓存成**全局值**，此后每个窗口的第一次 `ShowWindow` 都用它。所以 `SW_HIDE`
是一个**进程级锁死状态**，外部无法复位；补发一条 `WM_CLOSE` 让程序自己跑一次 `win.hide()`
也不管用（`hide()` 之后再 `show()`，走的仍是缓存里那个 `SW_HIDE`）。

三种启动方式，同一套 2 ms 采样的实测：

| `STARTUPINFO.wShowWindow` | 窗口在屏 | 托盘能找回 |
|---|---|---|
| `SW_SHOWNORMAL` (1) | 46 ms 起可见 | 能 |
| `SW_SHOWMINNOACTIVE` (7) | 39 ms 起可见 | 能 |
| **`SW_HIDE` (0)** | **从未出现** | **不能 —— 状态锁死** |

结论：拿一个「窗口从此找不回来」去换零闪烁，不划算。**保持现在这样**：`SW_SHOWNORMAL`
起，立刻发 `WM_CLOSE`，一闪之后收进托盘。

登录时那一闪是几帧、亚秒级（取决于 100 ms 轮询命中的时机），用户已确认可接受。
若哪天还想再压，唯一没试过的方向是**不碰 `STARTUPINFO`**、只把轮询间隔降到 ~1 ms 且
`SettleMs` 归零，把在屏时间从几百毫秒压到几十毫秒 —— 本次没做。

`-SettleMs` 默认 150ms 而不是更大，是因为窗口在屏幕上可见的时间就等于这段延迟 ——
而它其实不是必需的安全边距：`WM_CLOSE` 只有在 FLTK 事件循环跑起来之后才可能被派发，
那时候 `Tray::start()` 早就返回了（`src/ui.rs:937` 显示窗口，`:940` 建托盘，`:959` 才进循环）。

## 三个注意事项

1. **窗口收进托盘后，UI 的唯一入口就是托盘图标。** 别在任务栏设置里把它藏进折叠区丢掉了。
   真找不到，还有 Fn→Control Center 和重启两条后路；风扇不会失控（曲线按「任意温度都能安全长挂」设计）。
2. **在程序界面里动「开机自启」勾选会把计划任务整个重写**，改回裸 exe，弹窗行为就回来了。
   动过之后重新跑一遍 `-Mode Install`。`-Mode Show` 任何时候都能告诉你当前指向谁。
3. **这套东西依赖 `closeToTray` 保持为 `true`。** 关掉它的话，`WM_CLOSE` 会走到退出分支
   （`src/ui.rs:1465`），程序会启动后立刻退出 —— 不危险（退出时 worker 会发 `0x69` 交还固件），
   但自启就等于没开。日志里会明确写 `WARNING  process exited: it took the exit path`。

## 环境

- exe `8bc9d40104babf90bc2aaa0c987424eb7ec5b3a25173a0d8fbc49f837c559a69`
- 计划任务 `ClevoFanControl`，动作已指向 `<安装目录>\start-hidden.ps1`
- 参考源码 `XiaoQing235/ClevoFanControl` tag `v2.0.0`
