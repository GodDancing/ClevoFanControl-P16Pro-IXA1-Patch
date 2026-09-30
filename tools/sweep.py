#!/usr/bin/env python3
"""固件风扇曲线扫描（纯只读，零写入）。

目的：把本机 EC 固件**自己**的 (温度 -> 占空比) 关系量出来，作为设计正式曲线的基准。
手段：加一段有界 CPU 负载把温度推上去，同时密集采样；然后卸载，继续采样降温段
（降温段能看出固件的回差/hysteresis）。

安全性：
  - 全程只调用 GetDCHU_Data_Buffer（0x0D / 0x0C），**不调用 SetDCHU_Data**，不写 EC。
  - 超温自动中止：任一通道温度 >= --max-temp 立即杀掉负载。
  - 前置检查：若当前占空比是接管测试曲线的 50/85，说明接管还开着，直接拒绝运行
    （否则采到的是测试曲线而不是固件行为）。

用法:
    python sweep.py                          # 默认：全核负载 75s，降温观察 150s
    python sweep.py --load-seconds 90 --max-temp 93
    python sweep.py --procs 8                # 想温和一点
"""
import argparse
import os
import subprocess
import sys
import time

from monitor import Ec

CREATE_NO_WINDOW = 0x08000000
TAKEOVER_DUTIES = (50, 85)  # 接管测试曲线的特征值


def spawn_load(n):
    """起 n 个子进程跑死循环吃满 CPU，返回进程列表。"""
    procs = []
    for _ in range(n):
        procs.append(
            subprocess.Popen(
                [sys.executable, "-c", "while True: pass"],
                creationflags=CREATE_NO_WINDOW,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        )
    return procs


def kill_load(procs):
    for p in procs:
        try:
            p.kill()
        except Exception:
            pass
    for p in procs:
        try:
            p.wait(timeout=5)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--load-seconds", type=float, default=75.0)
    ap.add_argument("--cooldown-seconds", type=float, default=150.0)
    ap.add_argument("--idle-seconds", type=float, default=10.0)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--max-temp", type=int, default=93)
    ap.add_argument("--csv", default="sweep.csv")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    ec = Ec()
    ec.count = ec.fan_count()
    if not 1 <= ec.count <= 3:
        print(f"# 风扇数量异常 {ec.count}，停止")
        return 2

    # --- 前置检查：接管必须关着 ---
    for _ in range(4):
        _, s = ec.sample()
        d = tuple(c["duty"] for c in s)
        if d == TAKEOVER_DUTIES:
            print(f"# 当前占空比 {d} = 接管测试曲线特征值 —— 接管还开着。")
            print("# 请先在界面里关闭「软件接管」，再重新运行本扫描。")
            print("# （否则采到的是测试曲线，不是固件自己的行为）")
            return 3
        time.sleep(1.0)
    print(f"# 前置检查通过：当前占空比 {d}，不像接管值")

    fh = open(args.csv, "w", encoding="utf-8")
    fh.write("t,phase,fan1_temp,fan1_duty,fan1_rpm,fan2_temp,fan2_duty,fan2_rpm\n")

    start = time.monotonic()
    procs = []
    aborted = False

    def tick(phase):
        nonlocal aborted
        try:
            _, s = ec.sample()
        except OSError as e:
            print(f"  采样失败: {e}")
            return None
        t = time.monotonic() - start
        row = [f"{t:.2f}", phase]
        for c in s:
            row += [c["temp"], c["duty"], c["rpm"]]
        fh.write(",".join(str(v) for v in row) + "\n")
        fh.flush()
        cells = "  ".join(
            f"{c['temp']:>3}C {c['duty']:>3}% {str(c['rpm']):>5}rpm" for c in s
        )
        print(f"[{t:7.1f}s {phase:>8}] {cells}")
        if max(c["temp"] for c in s) >= args.max_temp:
            aborted = True
        return s

    try:
        print(f"# 阶段 1/3 静置 {args.idle_seconds:.0f}s（记录基线）")
        t_end = time.monotonic() + args.idle_seconds
        while time.monotonic() < t_end:
            tick("idle")
            time.sleep(args.interval)

        print(f"# 阶段 2/3 负载 {args.procs} 进程，最多 {args.load_seconds:.0f}s，"
              f"温度 >={args.max_temp}C 立即中止")
        procs = spawn_load(args.procs)
        t_end = time.monotonic() + args.load_seconds
        while time.monotonic() < t_end:
            s = tick("load")
            if aborted:
                print(f"# 达到 {args.max_temp}C，提前卸载")
                break
            time.sleep(args.interval)

        print(f"# 阶段 3/3 卸载，降温观察 {args.cooldown_seconds:.0f}s")
        kill_load(procs)
        procs = []
        t_end = time.monotonic() + args.cooldown_seconds
        while time.monotonic() < t_end:
            tick("cool")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n# 手动中断")
    finally:
        kill_load(procs)
        fh.close()

    print(f"# 完成，数据写入 {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
