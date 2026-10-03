# 验证脚本

这些脚本用于验证 `../mac-charging-menubar-design.md` 中的每一条实测结论。
数据源全部为系统框架（IOKit / libproc），无需 root 权限。

这些脚本**不参与应用构建**，只在需要复现设计文档里的实测数字时才编译运行。

## 编译与运行

```bash
cd docs/probe
clang -O2 -include unistd.h -o energy_probe energy_probe.c && ./energy_probe
clang -O2 -include unistd.h -o uidprobe     uidprobe.c     && ./uidprobe
clang -O2 -include unistd.h -o energy_delta energy_delta.c && ./energy_delta 5
clang -O2 -include unistd.h -o sum          sum.c          && ./sum 5
clang -O2 -include unistd.h -o pid_energy   pid_energy.c   && ./pid_energy 1 3
swiftc -O -o power_probe power_probe.swift && ./power_probe
swiftc -O -o perf_probe  perf_probe.swift  && ./perf_probe
swiftc -O -o series      series.swift      && ./series
swiftc -O -o watch       watch.swift       && ./watch   # 观测需 150 秒
```

**抓插电跳变时序**（不需要编译，跑起来之后去插拔电源）：

```bash
./plug_transition.py            # 1 秒一拍，跑 180 秒
./plug_transition.py 0.2 300    # 0.2 秒一拍，跑 5 分钟
./plug_transition.py 0.5 0      # 0.5 秒一拍，一直跑到 Ctrl-C
```

它回答的是设计文档 §15「没验证的事」里那两条：`ExternalConnected` 与 `IsCharging` 的置位差多久
（插电提示"等到 `IsCharging` 才弹"的 4 秒上限就建立在这个延迟上）、
以及系统按充电上限保电切到电池放电时 `SystemPowerIn` 的真实读数（判据第 5 条依赖它）。
每次跳变打 ★ 行，结束时打一份延迟汇总 + 保电窗口的供电范围。

**本机应用的能耗 A/B**（改了轮询 / 采样逻辑后必跑）：

```bash
./ab_energy.sh <优化前可执行文件> <优化后可执行文件> [轮数] [每轮秒数]
# 例：./ab_energy.sh /tmp/WattupOld.app/Contents/MacOS/Wattup \
#                   ../../.build/Wattup.app/Contents/MacOS/Wattup 3 60
```

它自己拉起被测进程、静置 15 秒再测，弹窗保持关闭 —— 这一点是必须的：
**弹窗开着时轮询是 1 秒/次、能耗扫描 2 秒/次；关着时是 5 秒 / 60 秒。**
同一份二进制，这两种状态下的 CPU 时间能差好几倍。直接测"当前正在跑的那个实例"，
前后两次能测出 5 倍以上的波动，等于没测。

## 脚本与结论对应表

| 脚本 | 验证结论 |
|---|---|
| `energy_probe.c` | 无 root 下能耗读取成功率 |
| `uidprobe.c` | 权限边界严格等价于用户归属（同 uid 497/497 可读，异 uid 0/201） |
| `sum.c` | 四个能耗计数器量纲标定，选定 `ri_energy_nj` |
| `energy_delta.c` | 计数器为单调累计量，须差分求速率 |
| `pid_energy.c` | **单个常驻进程**的能耗 / CPU / **空闲唤醒次数**（菜单栏工具的空闲能耗主要由唤醒次数决定，只看 CPU 会漏掉大头） |
| `ab_energy.sh` | 两个构建的受控 A/B：同条件、多轮、取最小值与中位数 |
| `power_probe.swift` | IOKit 全字段读取；`SystemPowerIn − SystemLoad = BatteryPower` 恒等式校验 |
| `perf_probe.swift` | 采样耗时（0.29 / 0.061 / 1.09 ms）；`AppleSMC` 可非特权打开 |
| `series.swift` | 逐秒采样；抓到"适配器 18.3 W、系统负载 22.2 W、电池倒灌 3.9 W"场景 |
| `watch.swift` | 150 秒观测，确认刷新周期精确为 60 秒 |
| `plug_transition.py` | 插电 → `IsCharging` 置位的延迟；保电放电窗口内的供电读数（§15「没验证的事」） |
