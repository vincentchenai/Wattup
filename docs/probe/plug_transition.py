#!/usr/bin/env python3
"""抓「插上电源 → 真正开始充电」的跳变时序。

为什么需要它：设计文档 §15「没验证的事」里那两条，靠读代码或读 `pmset -g log` 都补不上：

  1. `ExternalConnected` 与 `IsCharging` 的置位到底差多久？
     插电提示改成"等到 IsCharging 才弹"就是基于这个延迟，但一直没量过它有多大。
  2. 系统按充电上限保电（`drain = True`）切到电池放电的那几秒，`SystemPowerIn` 读数是多少？
     `isNetDischargingWhilePlugged` 的第 5 条判据（`SystemPowerIn > 0.5 W`）依赖它。

用法：

    ./plug_transition.py            # 1 秒一拍，跑 180 秒
    ./plug_transition.py 0.2 300    # 0.2 秒一拍，跑 5 分钟
    ./plug_transition.py 0.5 0      # 0.5 秒一拍，一直跑到 Ctrl-C

跑起来之后再去插拔电源。脚本会在每次跳变时打 ★ 行，结束时（或 Ctrl-C）打一份汇总。

**采样期间不要盖着屏幕 / 别让机器睡** —— 那些状态下读数会停更。

两个读 ioreg 的坑（本项目踩过，见设计文档附录）：
  * `ExternalConnected` / `IsCharging` / `FullyCharged` 打印成 **Yes / No**，不是 1 / 0；
    只匹配数字的正则会静默把它们读成 0。
  * **凡是有符号量都按无符号 64 位打印**：`Amperage`（放电时）、`BatteryPower`（电池放电时，
    实测打印成 18446744073709543776 而不是 -7840）、`SystemLoad` 同理。负数必须减 2^64。
    这个坑很隐蔽 —— 直接看会在表格里看到一串 20 位数字还以为是"很大的功率"。
"""

import re
import subprocess
import sys
import time

KEYS = [
    "ExternalConnected", "IsCharging", "FullyCharged", "CurrentCapacity",
    "Amperage", "Voltage", "SystemPowerIn", "BatteryPower", "SystemLoad",
    "UpdateTime",
]
FIELD = re.compile(r'"(%s)"\s*=\s*([^,}\n]*)' % "|".join(KEYS))
UINT64 = 1 << 64
I64_MAX = (1 << 63) - 1

PMSET_SOURCE = re.compile(r"now drawing from '([^']+)'", re.I)
PMSET_STATUS = re.compile(r"\d+%;\s*([a-z ]+);", re.I)


def flag(text):
    """ioreg 把布尔打印成 Yes / No。"""
    return 1 if text.strip() == "Yes" else 0


def number(text, default=0):
    try:
        return int(text.strip())
    except ValueError:
        return default


def signed(text, default=0):
    """ioreg 把有符号量按无符号 64 位打印：放电电流、电池放电功率都会变成 20 位大数。

    实测 BatteryPower 在电池放电时打印成 18446744073709543776（= -7840 mW），
    不做这一步就会在表格里看到一个"巨大的正功率"。
    """
    value = number(text, default)
    return value - UINT64 if 0 < value > I64_MAX else value


def read_pmset():
    """powerd / IOPS 视角（应用侧 `PowerModel.mergedIsCharging` 的仲裁来源）。

    `pmset -g batt` 与 IOPS 同源：系统菜单栏电池图标显示什么，它就报什么。
    放这一列是为了在下次插电时直接对比 —— ioreg 的 `IsCharging` 和它谁先翻身、差多少。
    """
    out = subprocess.run(["pmset", "-g", "batt"],
                         capture_output=True, text=True, timeout=5).stdout
    src = PMSET_SOURCE.search(out)
    status = PMSET_STATUS.search(out)
    return {
        "ac": bool(src and "AC" in src.group(1)),
        "charging": bool(status and status.group(1).strip().startswith("charging")
                         and "discharging" not in status.group(1)),
    }


def read_snapshot():
    out = subprocess.run(
        ["ioreg", "-r", "-c", "AppleSmartBattery", "-w0"],
        capture_output=True, text=True, timeout=5,
    ).stdout

    raw = {}
    for key, value in FIELD.findall(out):
        raw.setdefault(key, value)  # 同名键取第一次出现（顶层优先）

    return {
        "ext": flag(raw.get("ExternalConnected", "No")),
        "chg": flag(raw.get("IsCharging", "No")),
        "full": flag(raw.get("FullyCharged", "No")),
        "cap": number(raw.get("CurrentCapacity", "0")),
        "amp": signed(raw.get("Amperage", "0")),
        "volt": signed(raw.get("Voltage", "0")),
        "sysin": signed(raw.get("SystemPowerIn", "0")),
        "batp": signed(raw.get("BatteryPower", "0")),
        "load": signed(raw.get("SystemLoad", "0")),
        "upd": raw.get("UpdateTime", "-").strip(),
    }


def main():
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 180.0

    print("时刻          Ext Chg Full Cap  A(mA)   V(mV)  SysIn    BattP    Load     PM(AC 充) 相对墙钟")
    print("            （SysIn / BattP / Load 单位 mW；BattP 为负 = 电池在放电；PM = pmset/IOPS 视角）")
    print("-" * 100)

    start = time.time()
    prev = None
    events = []          # (t, 说明)
    ext_on_at = None     # 最近一次 ExternalConnected 0→1
    idle_windows = []    # 「接了电但没在充电」的窗口：[(起点, 终点或 None, [sysin...])]
    current_idle = None

    try:
        while True:
            now = time.time()
            elapsed = now - start
            if duration > 0 and elapsed > duration:
                break

            snap = read_snapshot()
            snap.update(read_pmset())
            stamp = time.strftime("%H:%M:%S") + f".{int(now % 1 * 1000):03d}"

            print(
                f"{stamp}  {snap['ext']}   {snap['chg']}   {snap['full']}   "
                f"{snap['cap']:>3}  {snap['amp']:>6}  {snap['volt']:>5}  "
                f"{snap['sysin']:>6}  {snap['batp']:>6}  {snap['load']:>6}   "
                f"  {int(snap['ac'])}   {int(snap['charging'])}    +{elapsed:7.2f}s"
            )

            if prev is not None:
                if snap["ext"] != prev["ext"]:
                    mark = "插电" if snap["ext"] else "拔电"
                    print(f"  ★ {mark}：ExternalConnected {prev['ext']} → {snap['ext']}"
                          f"  （+{elapsed:.2f}s，电量 {snap['cap']}%，pmset 充电={snap['charging']}）")
                    events.append((elapsed, mark))
                    if snap["ext"]:
                        ext_on_at = elapsed
                        current_idle = [elapsed, None, []]
                        idle_windows.append(current_idle)
                    else:
                        if current_idle is not None:
                            current_idle[1] = elapsed
                            current_idle = None

                if snap["chg"] != prev["chg"]:
                    mark = "IsCharging 置位" if snap["chg"] else "IsCharging 落位"
                    lag = ""
                    if snap["chg"] and ext_on_at is not None:
                        lag = f"  ← 距插电 {elapsed - ext_on_at:.2f}s"
                    print(f"  ★ {mark}（+{elapsed:.2f}s，电量 {snap['cap']}%，"
                          f"SysIn {snap['sysin'] / 1000:.1f}W）{lag}")
                    events.append((elapsed, mark))
                    if snap["chg"] and current_idle is not None:
                        current_idle[1] = elapsed
                        current_idle = None

                if snap["full"] != prev["full"]:
                    print(f"  ★ FullyCharged {prev['full']} → {snap['full']}"
                          f"（+{elapsed:.2f}s，电量 {snap['cap']}%）")

                if snap["charging"] != prev["charging"]:
                    mark = "pmset 报在充" if snap["charging"] else "pmset 报没充"
                    lag = f"  ← 距插电 {elapsed - ext_on_at:.2f}s" if snap["charging"] and ext_on_at is not None else ""
                    print(f"  ★ {mark}（+{elapsed:.2f}s）{lag}")
                    events.append((elapsed, mark))

                if snap["upd"] != prev["upd"]:
                    print(f"  · 电量计刷新（UpdateTime 变了，+{elapsed:.2f}s）")

            # 接电未充电的窗口里，记下供电读数
            if current_idle is not None and snap["ext"] and not snap["chg"]:
                current_idle[2].append((snap["sysin"], snap["batp"], snap["load"]))

            prev = snap
            time.sleep(interval)

    except KeyboardInterrupt:
        print()

    # ---------------- 汇总 ----------------
    total = time.time() - start
    print("=" * 88)
    print(f"采样 {total:.1f} 秒，共记录 {len(events)} 次跳变")

    # 插电 → IsCharging 的延迟
    lags = []
    pmset_lags = []
    last_ext = None
    for t, what in events:
        if what == "插电":
            last_ext = t
        elif what == "IsCharging 置位" and last_ext is not None:
            lags.append(t - last_ext)
            last_ext = None
        elif what == "pmset 报在充" and last_ext is not None:
            pmset_lags.append(t - last_ext)

    if lags or pmset_lags:
        print(f"\n插电 → 各来源报「在充」的延迟：")
        if pmset_lags:
            print(f"  pmset / IOPS（powerd）：{len(pmset_lags)} 次，"
                  f"最小 {min(pmset_lags):.2f}s ／ 最大 {max(pmset_lags):.2f}s ／ "
                  f"中位数 {sorted(pmset_lags)[len(pmset_lags) // 2]:.2f}s")
        if lags:
            print(f"  ioreg IsCharging（电量计）：{len(lags)} 次，"
                  f"最小 {min(lags):.2f}s ／ 最大 {max(lags):.2f}s ／ "
                  f"中位数 {sorted(lags)[len(lags) // 2]:.2f}s")
        if pmset_lags and lags:
            n = min(len(pmset_lags), len(lags))
            print(f"  两者之差（电量计滞后多少）：前 {n} 组平均 "
                  f"{sum(sorted(lags)[i] - sorted(pmset_lags)[i] for i in range(n)) / n:.2f}s")
        print("\n  → 应用已改为 IOPS 优先仲裁（PowerModel.mergedIsCharging）——")
        print("    上面的 pmset 延迟就是用户能感知到的「插上后多久显示正在充电」。")
    else:
        print("\n没抓到「插电 → 正在充电」的完整过程 —— 插拔一次电源再跑一遍。")

    # 接电未充电窗口（保电放电就落在这里）
    if idle_windows:
        print(f"\n接电但未在充电的窗口（{len(idle_windows)} 段）—— 系统保电放电就发生在这里：")
        for begin, end, samples in idle_windows:
            span = f"{(end - begin):.2f}s" if end is not None else "未结束"
            if samples:
                sysin = [s[0] for s in samples]
                batp = [s[1] for s in samples]
                print(f"  +{begin:.2f}s 起，持续 {span}；共 {len(samples)} 个采样")
                print(f"      SystemPowerIn  {min(sysin) / 1000:.2f} – {max(sysin) / 1000:.2f} W")
                print(f"      BatteryPower   {min(batp) / 1000:.2f} – {max(batp) / 1000:.2f} W"
                      f"（负=电池在放电）")
            else:
                print(f"  +{begin:.2f}s 起，持续 {span}；窗口内没有落在「接电未充电」的采样")
        print("\n  → 判据第 5 条要求窗口内 SystemPowerIn > 0.5 W。若上面最小值贴近 0，"
              "说明该判据会在保电放电时误放行，需要收紧。")
    else:
        print("\n没有出现「接电但未在充电」的窗口。")


if __name__ == "__main__":
    main()
