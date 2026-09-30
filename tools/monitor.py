#!/usr/bin/env python3
"""ClevoFanControl 只读监视器。

只调用 GetDCHU_Data_Buffer（0x0D 取风扇数、0x0C 取遥测），**绝不调用 SetDCHU_Data**，
不对 EC 做任何写入。用于在验证/使用接管期间连续观察温度、占空比、转速，
并与 Control Center 对照。

读写语义取自上游 v2.0.0 的 src/hardware.rs：
    cmd 0x0D -> b[12]       风扇数量
    cmd 0x0C -> b[18+i*3]   温度 (摄氏度)
                b[16+i*3]   实际占空比 (raw -> percent)
                b[2+i*2]    转速计数器 (大端 u16)

用法:
    python monitor.py                  # 每秒采样，Ctrl+C 结束
    python monitor.py --seconds 60     # 采 60 秒
    python monitor.py --raw            # 额外打印遥测区原始字节
    python monitor.py --csv out.csv    # 同时写 CSV
"""
import argparse
import ctypes
import sys
import time

DLL_PATH = r"C:\ProgramData\ClevoFanControl\InsydeDCHU-FnKey.dll"
# 与程序用的一致：LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32
LOAD_FLAGS = 0x100 | 0x800
SENTINEL = 0xA5
BUFFER_LEN = 4096


def to_percent(raw: int) -> int:
    """上游 control.rs: (raw * 100 + 127) / 255"""
    return (raw * 100 + 127) // 255


def decode_rpm(counter: int):
    """上游 hardware.rs: round(2156250 / counter)，0 表示 0，>20000 视为无效"""
    if counter == 0:
        return 0
    rpm = round(2156250 / counter)
    return rpm if rpm <= 20000 else None


class Ec:
    def __init__(self, path=DLL_PATH):
        # winmode 会作为 dwFlags 直接传给 LoadLibraryExW
        self.dll = ctypes.WinDLL(path, winmode=LOAD_FLAGS)
        self.get = self.dll.GetDCHU_Data_Buffer
        self.get.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint8)]
        self.get.restype = ctypes.c_int32

    def buffer(self, cmd: int):
        buf = (ctypes.c_uint8 * BUFFER_LEN)(*([SENTINEL] * BUFFER_LEN))
        ret = self.get(cmd, buf)
        if ret != cmd or all(v == SENTINEL for v in buf[:256]):
            raise OSError(f"读取 EC 命令 {cmd:#x} 失败（返回 {ret:#x}）")
        return bytes(buf)

    def fan_count(self) -> int:
        return self.buffer(0x0D)[12]

    def sample(self):
        b = self.buffer(0x0C)
        out = []
        for i in range(self.count):
            out.append(
                {
                    "temp": b[18 + i * 3],
                    "duty": to_percent(b[16 + i * 3]),
                    "duty_raw": b[16 + i * 3],
                    "rpm": decode_rpm((b[2 + i * 2] << 8) | b[3 + i * 2]),
                    "rpm_counter": (b[2 + i * 2] << 8) | b[3 + i * 2],
                }
            )
        return b, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=0, help="采样时长，0 = 直到 Ctrl+C")
    ap.add_argument("--interval", type=float, default=1.0, help="采样间隔秒，默认 1.0")
    ap.add_argument("--raw", action="store_true", help="打印遥测区原始字节")
    ap.add_argument("--csv", help="同时写入 CSV")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    ec = Ec()
    ec.count = ec.fan_count()
    print(f"# DLL  {DLL_PATH}")
    print(f"# 风扇数量 {ec.count}")
    if not 1 <= ec.count <= 3:
        print(f"# 风扇数量异常，停止")
        return 2

    fh = open(args.csv, "w", encoding="utf-8") if args.csv else None
    if fh:
        cols = ["t"]
        for i in range(ec.count):
            cols += [f"fan{i+1}_temp", f"fan{i+1}_duty", f"fan{i+1}_rpm"]
        fh.write(",".join(cols) + "\n")
        fh.flush()

    print("# " + "  ".join(f"风扇{i+1}(温度/占空比/转速)" for i in range(ec.count)))
    start = time.monotonic()
    failures = 0
    try:
        while True:
            t = time.monotonic() - start
            if args.seconds and t >= args.seconds:
                break
            try:
                raw, s = ec.sample()
                failures = 0
            except OSError as e:
                failures += 1
                print(f"[{t:7.1f}s] 采样失败: {e}")
                if failures > 5:
                    print("# 连续失败过多，停止")
                    break
                time.sleep(args.interval)
                continue

            cells = "  ".join(
                f"{c['temp']:>3}°C {c['duty']:>3}% {str(c['rpm']):>5}rpm" for c in s
            )
            extra = f"   raw={raw[:32].hex(' ')}" if args.raw else ""
            print(f"[{t:7.1f}s] {cells}{extra}")
            if fh:
                row = [f"{t:.1f}"]
                for c in s:
                    row += [c["temp"], c["duty"], c["rpm"]]
                fh.write(",".join(str(v) for v in row) + "\n")
                fh.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n# 已中断")
    finally:
        if fh:
            fh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
