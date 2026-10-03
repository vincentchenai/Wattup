# Mac 充电状态菜单栏工具 · 设计方案

> 验证环境：MacBook Air M5（Mac17,3）/ macOS 26.6.2（25G83）/ Xcode 26 / Apple clang 21
> 本文中所有标注「实测」的数据，均来自本机真机采样，附可复现命令。

---

## 1. 结论

**可行，而且比预期干净。** 六项需求（电量、功率、电流、电压、电池详情、应用耗电排行）全部有稳定数据源，且**不需要 root 权限、不需要内核扩展、不需要任何第三方库**。整轮采集耗时不到 1.5 ms。

但有两个必须写进产品定义、不能靠营销话术绕开的边界：

1. **功率读数每 60 秒才刷新一次。** 实测 `AppleSmartBattery` 的 `UpdateTime` 与 `Amperage` 在 150 秒观测里只变了 3 次，间隔精确为 60、60 秒。所谓"实时瓦数"本质是**每分钟一次的采样值**。这一条决定了产品叙事：可以做得很好看，但不能承诺秒级真值。
2. **应用能耗排行只能覆盖当前用户进程。** 实测权限边界严格等价于用户归属：同 uid 497 个进程全部可读、0 个被拒；异 uid 201 个进程全部被拒、0 个成功，零例外。加上 GPU / ANE / 显示 / 内存功耗不归属到进程，**进程能耗合计只占整机 SystemLoad 的约 8%**。因此该排行只能做**相对排序**，不能当绝对瓦数。

把这两条讲清楚，反而比竞品更值得信任——竞品页面上的"实时"同样受制于 60 秒刷新率，只是没说。

---

## 2. 需求 → 数据源映射（全部实测）

| 展示项 | 数据来源 | 实测原始值 | 换算 / 说明 |
|---|---|---|---|
| 电量百分比 | `CurrentCapacity` / `IOPSCopyPowerSourcesInfo` | `76` | 76% |
| 充放电状态 | `IsCharging` / `FullyCharged` / `ExternalConnected` | `Yes / No / Yes` | 充电中 |
| 剩余时间 | `TimeRemaining` / `Time to Full Charge` | `169 min` | 2:49 |
| 电池电压 | `Voltage` | `12525` mV | 12.53 V |
| 电池电流 | `Amperage` / `InstantAmperage` | `197` mA | **正 = 充电，负 = 放电**（两向均已实测） |
| 电池端功率 | `Voltage × Amperage` | `2467` mW | 2.47 W |
| 适配器输入功率 | `PowerTelemetryData.SystemPowerIn` | `18333` mW | 18.33 W（真实进入主板的 DC 功率） |
| 系统负载功率 | `PowerTelemetryData.SystemLoad` | `15866` mW | 15.87 W |
| 电池净功率 | `PowerTelemetryData.BatteryPower` | `2467` mW | 2.47 W（正充负放） |
| 主板侧输入电流/电压 | `SystemCurrentIn` / `SystemVoltageIn` | `2143` mA / `8554` mV | |
| 适配器传输损耗 | `AdapterEfficiencyLoss` | `760` mW | 可作进阶指标 |
| 适配器额定功率 | `AdapterDetails.Watts` | `20` | 20 W |
| 适配器协商电压/电流 | `AdapterVoltage` / `Current` | `9000` mV / `2220` mA | 9 V @ 2.22 A |
| 适配器 PD 档位表 | `AdapterDetails.UsbHvcMenu` | `[{5V,3A},{9V,2.22A}]` | 可展示"能协商到哪些档" |
| 充电目标电流/电压 | `ChargerData.ChargingCurrent` / `ChargingVoltage` | `2876` mA / `4258` mV | 区别于适配器输出 |
| 充不进电的原因 | `ChargerData.NotChargingReason` / `SlowChargingReason` | `0` / `0` | 0 = 无异常，非 0 可诊断 |
| 电池温度 | `Temperature` / `VirtualTemperature` | `3089` / `3569` | 30.9 °C / 35.7 °C（1/100 °C） |
| 电芯电压 | `BatteryData.CellVoltage` | `(4188, 4188, 4185)` mV | 三芯不一致度可作健康信号 |
| 电芯内阻 | `BatteryData.WeightedRa` | `(62, 71, 71)` | 进阶健康指标 |
| 循环次数 | `CycleCount` / `DesignCycleCount9C` | `17` / `1000` | 17 / 1000 次 |
| 设计容量 | `DesignCapacity` | `4629` mAh | |
| 当前满充容量 | `AppleRawMaxCapacity` | `4702` mAh | 健康度 = 4702/4629 |
| 标称容量 | `NominalChargeCapacity` | `4829` mAh | |
| 电池健康状况 | `IOPSCopyPowerSourcesInfo` → `BatteryHealth` | `Good` | 公开 API，非私有字段 |
| 累计使用时长 | `LifetimeData.TotalOperatingTime` | `3536` min | 58.9 小时 |
| 应用耗电排行 | `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` 差分 | 见 §3.5 | 需两次采样求速率 |
| 系统充电策略 | `/Library/Preferences/com.apple.powerd.charging.plist` 的 `policies` 归档 | `reason=optimizedBatteryCharging`、`soclimit=80` | **只读**，不需要权限；详见 §14 |

### 功率恒等式（两套独立算法互证）

```
SystemPowerIn − SystemLoad = BatteryPower        （遥测口径）
Voltage × Amperage          = BatteryPower        （物理口径）
```

实测校验（充电态，快照 A）：`18333 − 15866 = 2467` ✓，`12525 × 0.197 = 2467` ✓
实测校验（放电态，快照 B）：`18312 − 22174 = −3862` ✓，`12541 × (−0.308) = −3863` ✓

两套算法在两种状态下都吻合（误差 1 mW），可以互为交叉校验——这是本方案的核心数据质量保证。

---

## 3. 实测证据

### 3.1 采集成本（决定轮询策略的关键数据）

| 操作 | 实测耗时 |
|---|---|
| `AppleSmartBattery` 全量属性读取（100 次平均） | **0.29 ms** |
| 同上，单次（含服务匹配） | 0.19 – 0.21 ms |
| `IOPSCopyExternalPowerAdapterDetails`（100 次平均） | **0.061 ms** |
| 全进程 `proc_pid_rusage(RUSAGE_INFO_V6)` 扫描（550 进程） | **1.09 ms** |

即使按 1 Hz 全量轮询，CPU 占用也在 0.1% 量级。**性能完全不是约束，可以放心把刷新做频繁。**（复现命令见文末）

### 3.2 刷新节律：精确 60 秒

150 秒逐秒采样 `UpdateTime` 与 `Amperage`：

```
UpdateTime  : 变化 3 次  各次间隔(s): 60, 60
Amperage    : 变化 3 次  各次间隔(s): 60, 60
```

30 秒的短窗口内所有功率字段**零变化**——所以短时间反复采样拿到的是一模一样的值。

设计含义：
- 1 Hz 轮询这个数据源**是浪费**，正确做法是每 5 秒读一次（0.29 ms）、比对 `UpdateTime`，未变化就不触发 UI 更新。
- UI 想做出 Juicy 那种流畅动画，只能靠**对 60 秒采样值做插值平滑**。这是装饰，不是测量。
- **建议在界面上明示「采样于 N 秒前」**，把"看起来在动"和"真的在测"区分开。这是本产品相对竞品的差异化信任点。
- 待测：放电态与快充高负载下刷新率是否仍为 60 秒（本次未拔电源，无法验证）。

### 3.3 权限边界严格等价于用户归属

```
当前 uid = 501
  同 uid  成功 = 497 , 同 uid  被拒 = 0
  异 uid  成功 = 0   , 异 uid  被拒 = 201
```

零例外。含义很明确：应用不需要任何特权就能做完整监控，但要接受"只看得到自己的进程"；系统守护进程（`powerd`、`WindowServer` 等）永远不出现在排行里。

### 3.4 能耗计数器的量纲标定

同一 5 秒窗口、同一批进程，`rusage_info_v6` 里四个计数器差异极大：

| 字段 | 窗口内合计 | 折算功率 | 是否采用 |
|---|---|---|---|
| `ri_energy_nj` | 6.717 J | **1.34 W** | ✅ 主指标 |
| `ri_penergy_nj` | 5.715 J | 1.14 W | 辅助 |
| `ri_billed_energy` | 0.148 J | 29.5 mW | ❌ 量级偏离 |
| `ri_serviced_energy` | 0.132 J | 26.4 mW | ❌ 量级偏离 |

`ri_energy_nj` 折算出的 1.34 W 与整机 CPU 侧功耗量级吻合（SystemLoad 15.87 W，其中显示 / GPU / 内存 / 外设占大头），故选它。`ri_billed_energy` 的语义 Apple 未公开说明，量级差约 100 倍，暂不采用——这是一个需要长期标定的项。

**关键背景数字：进程能耗合计 1.34 W ÷ 整机 SystemLoad 15.87 W ≈ 8%。** 这个比例必须在 UI 里讲清楚，否则用户会以为排行加起来应该等于整机功耗。

### 3.5 差分法有效性与真实排行样本

5 秒窗口、549 个进程中 **469 个有能耗增量**（即该计数器为单调累计量，必须差分求速率）。同 uid 454 个进程的实测排行：

| 进程 | 窗口增量折算 |
|---|---|
| 虚拟机服务 | 253 mW |
| WindowManager | 27 mW |
| Chrome 渲染进程 | 20 mW |
| Docker 后端 | 19 mW |
| Google Chrome | 19 mW |
| DingTalk | 16 mW |

### 3.6 顺手抓到一个真实场景：20 W 充电器不够用

观测中捕捉到快照 B 这个状态——**适配器插着，电池却在放电**：

```
SystemPowerIn = 18312 mW   （适配器只送出 18.3 W）
SystemLoad    = 22174 mW   （整机在吃 22.2 W）
BatteryPower  = −3862 mW   （电池倒贴 3.9 W）
ExternalConnected = Yes,  Amperage = −308 mA
```

这恰好是 Juicy 花整个页面在卖的卖点（"揪出不给力的充电器"）。而这台机器用的是 **20 W 适配器推 M5 MacBook Air 跑 Docker + Chrome + PyCharm**——一个非常真实的开发场景。**建议把这个场景直接做成产品的一等公民功能：净放电告警**，即"插着电但电量仍在掉"时主动提示，并给出"需要 ≥ X W 适配器"的建议。

---

## 4. 未覆盖 / 待验证（不要当成已完成）

| 项 | 状态 |
|---|---|
| 放电态功率刷新率 | 未测（需拔电源），实测仅覆盖 AC 充电态 |
| Intel Mac 降级路径 | 未测。`PowerTelemetryData` 仅在 Apple Silicon 上确认存在；本机为 M5 |
| App Sandbox 下的 `proc_pid_rusage` | **未验证**。`sandbox-exec` 在当前执行环境内不可用（`Operation not permitted`），无法构造近似沙盒。已按最坏情况设计（不做 MAS 分发） |
| SMC key 读写协议 | 部分验证。`IOServiceMatching("AppleSMC")` 可匹配、`IOServiceOpen(type=0)` 返回 `kern_return = 0`，即**非特权进程可打开 SMC 用户客户端**；但具体 key 的读写协议未做实现级验证 |
| 无电池机型（Mac mini / Studio / Pro） | 未验证。`AppleSmartBattery` 不存在时需整机降级为"仅适配器信息" |
| 私有字段跨版本稳定性 | 无法验证。`PowerTelemetryData` / `ChargerData` / `BatteryData` 均无公开文档 |
| `LifetimeData.TotalOperatingTime`（累计使用时长） | **确认不可得**。`ioreg` 能看到，但 CF 桥接（`IORegistryEntryCreateCFProperties`）返回的 58 个键里**没有** `LifetimeData`。已从 UI 移除，不做兜底 |
| 点击状态项 → 弹窗 | 已实测。`button.performClick` 触发真实 action，`popover.isShown` 由 false → true，窗口 (890, 161, 362, 767)，内容 741 pt |
| 鼠标真实点击（非 `performClick`） | 未测。需要辅助功能权限注入鼠标事件，未走这条。注意：合成 `performClick` **不会**激活应用，弹窗会被前台窗口盖住；自检路径里补了 `NSApp.activate` |
| 低电量模式**写入** | **确认不可为**。实测 `pmset -b lowpowermode 1` → `'pmset' must be run as root...`（exit=1），`sudo -n true` → `Operation not permitted`。读取改为进程内公开 API（`ProcessInfo.isLowPowerModeEnabled`，见 §12），写入仍走 `pmset` 并尽力而为 + 失败引导到电池设置，不做静默兜底、不弹管理员密码框 |
| 真实插拔电源触发提示胶囊 | **未实测**。判定逻辑已用合成快照序列自检覆盖（`--selfcheck-power-event`：首次不发 / 重复不发 / 翻转各发一次 ✅）；"拔掉电源线时系统是否翻转 `isExternalConnected`"属系统行为，需真机拔插验证（`--watch-power-events`） |
| 弹窗滚动交互 | 部分实测。高度封顶与真实窗口位置已量（见 §7）；滚动手势本身未在弹窗内实测 |

### 实现状态（P0）

已实现并通过自检（`--verify-statusitem` / `--verify-popover` / `--ui-preview` 三个诊断入口）：

- 三个采集器全部落地：注册表遥测、公开 API 口径、进程能耗差分
- 状态项 + 自定义 `NSPopover` 弹窗（**不是 `MenuBarExtra`**，原因见 §5）
- 三档菜单栏形态（**电池指示器** / 极简 / 仅标志）＋ 四档附加读数（瓦数 / 百分比 / 剩余时长 / 不显示）
  ＋ 配色档位与大小三档、状态颜色开关；首启播种落位、`⌘`-拖拽位置记忆
- **UI 已按 Juicy 重做**（见 §7）：绿色主题、自绘药丸状态项、英雄卡 / 环形 / 条形进度 /
  图标芯片 / 迷你曲线 / 洞察卡，浅色与深色双外观自适应
- 弹窗高度封顶在程序坞之上 + 超出滚动；四个数据分区可折叠且状态持久化
- **应用内设置面板**（7 分栏，见 §11.1）：外观 / 提醒 / 告警阈值 / 用量 / 只读电池数据 / 关于；
  开机自启走 `SMAppService.mainApp` 真实状态
- 顶部居中提示胶囊（无边框 `NSPanel`，不抢焦点，见 §11.2）：插拔 + 三类一次性告警
- 低电量模式开关（读取 + 尽力写入 + 失败引导）
- 界面证据：`docs/shots/`
  - `popover_v6_light.png` / `popover_v6_dark.png` — 弹窗双外观（默认折叠组合，含新的「设置…」入口）
  - `popover_real_v5.png` — 真实点击状态项后弹出并屏幕截取（可看到下沿停在程序坞上方、底部退出按钮直接可见）
  - `menubar_v3_zoom.png` — 菜单栏药丸 + 瓦数双显（本机装有 Juicy，用启动前后差分确认这一个是自己的图标）
  - `toast_plug_v7.png` / `toast_unplug_v7.png` / `toast_low_v7.png` / `toast_discharge_v7.png` / `toast_temp_v7.png`
    — 五种提示胶囊版式
  - `toast_strip_v7.png` / `toast_strip_v7_dark.png` — 尺寸 × 光晕 九种组合对照图（双外观），改外观档位时的主要证据
  - `toast_compact_off_v7.png` / `toast_regular_v7.png` / `toast_roomy_strong_v7.png`
    — 真提示在三种档位下的实拍，用于量化柔光外扩范围（见 §11.3）
  - `screen_glow_regular.png` / `screen_glow_strong.png` — 屏幕边缘光带（默认 / 强烈档），
    各为一个 `1470 × bandHeight` pt 的带子本体；用于核对底部是否严格渐隐到 0
  - `toast_capsule_regular_v8.png` — 光带落地后重渲的「默认档」胶囊实拍
  - `settings_<pane>_v6.png`（6 张）+ `settings_general_v7.png` — 设置面板各分栏（通用栏本轮改版，单独升到 v7，
    已含「通知外观」组与新预览舞台）
  - `icon_states_light_v6.png` / `icon_states_dark_v6.png` / `icon_states_mark_v6.png`
    — 图标状态对照图，用于核对「闪电只在充电中出现」

被取代的 5 张 `toast_*_v6.png` 与 `settings_general_v6.png` 已移入 `docs/shots/_archive/`。

### 已知缺陷（已修）

- 适配器「未连接外接电源」误判：原以 `adapterName != nil` 判断连接，
  实测扩展坞/PD 源可能读不到 `AdapterDetails.Name`，导致正在 23 W 充电却显示未连接。
  已改为按供电事实判断，并在名称缺失时显式标注。
- `LifetimeData.TotalOperatingTime` 不可得 → 已从 UI 移除。
- `healthPercent` 上限截到 100%（原始值可能 101.6%）。
- **弹窗压到程序坞**：首版把 `popover.contentSize` 直接设为「状态项下沿 − 程序坞上沿」，
  实测真实窗口仍低 26 pt。原因是 `NSPopover` 自身有约 26 pt 外框（箭头 + 内容区上下内衬）
  没被算进去。已改为扣掉实测外框常量（见 §7）。
- **非充电状态也画闪电**：判据原为 `isCharging || isFullyCharged`，
  与 Juicy 语义不符（闪电 = 正在充电）。已改为只看 `isCharging`，
  并加了 `--icon-strip` 状态对照图把五种情形一次画出来核对。
- **提示胶囊文案被挤到换行**：HStack 里右侧大号数字先拿到宽度，
  中文说明列被压到折行。已给说明列加 `layoutPriority(1)`。


---

## 5. 技术选型

| 维度 | 选择 | 理由 |
|---|---|---|
| 语言 | Swift 6 | 与 IOKit / libproc C API 互操作零成本；并发安全模型适合多采样器 |
| UI | **`NSStatusItem` + `NSPopover` + SwiftUI 内容视图** | 原方案是 `MenuBarExtra`，但在手工组装的 SwiftPM `.app` bundle 里**状态栏不显示图标**；换成 `NSStatusItem` 后正常。富弹窗内容仍用 SwiftUI 承载 |
| 常驻形态 | `LSUIElement = true` + `.accessory` | 只驻菜单栏，不占 Dock |
| 第三方依赖 | **核心零依赖** | 数据源全是系统框架，引入依赖只会增加签名与维护面 |
| 自动更新 | Sparkle | 标准方案 |
| 开机自启 | `SMAppService.mainApp.register()` | 系统原生，省掉 `LaunchAtLogin` 这类库 |
| 本地存储 | SQLite（历史曲线用，P1） | 60 秒一个点，一天 1440 行，体积可忽略 |
| 分发 | Developer ID 签名 + 公证 + DMG + Homebrew Cask | 见下 |

### 分发渠道：明确不走 Mac App Store

理由：MAS 强制沙盒，而沙盒极可能切断跨进程能耗读取（§4 中标注为未验证，但按最坏情况设计）。若上 MAS，就必须砍掉"应用耗电排行"这个核心卖点。

**决策：Developer ID + 公证为主渠道，Homebrew Cask 为分发方式。** 代价是失去 App Store 的流量与信任背书，需要靠开源或独立站来补。

### 隐私声明

除 Sparkle 更新检查外不需要任何网络权限。可考虑在 `Info.plist` 中直接声明无网络能力，作为对"电池类工具会不会上传数据"这类疑虑的正面回应。

---

## 6. 架构与采样策略

架构分层见配套架构图：**数据源（3 个）→ 采集层（3 个独立 sampler）→ 聚合层（PowerModel）→ 呈现层（菜单栏图标 + 弹窗）**。

### 三个采集器

| 采集器 | 数据源 | 职责 |
|---|---|---|
| `RegistrySampler` | IOKit `AppleSmartBattery` + `IORegistryEntryCreateCFProperties` | 功率遥测、电池详情、适配器详情 |
| `PowerSourceSampler` | `IOPSCopyPowerSourcesInfo` / `IOPSCopyExternalPowerAdapterDetails` | 电量、健康、剩余时间、适配器公开字段 |
| `ProcessEnergySampler` | `sysctl(KERN_PROC_ALL)` + `proc_pid_rusage(RUSAGE_INFO_V6)` | 全进程能耗与 pid 归属 |

### 事件与轮询结合（基于 60 秒刷新率的针对性设计）

```
电源插拔 / 电量阈值变化
  → IOPSNotificationCreateRunLoopSource 回调（0.06 ms 读一次）
  → 立即触发全量刷新

常规轮询
  → 每 5 s 读 IORegistry（0.29 ms）
  → 若 UpdateTime 未变化 → 不触发 UI 更新（绝大多数时候走这条）
  → 若 UpdateTime 变化 → 刷新 UI，并记录"距上次采样 N 秒"

进程能耗差分
  → 弹窗打开：每 2 s 扫一次
  → 弹窗关闭：降到每 60 s（**与电量计刷新同拍**，搭同一次唤醒，不额外叫醒 CPU）

低电量模式 / 热压力等级变化
  → NSProcessInfoPowerStateDidChange 通知
  → 立即回读（进程内公开 API，零成本）；**不进轮询**
```

注意这里的关键取舍：**把 UI 刷新绑定到 `UpdateTime` 变化，而不是绑定到定时器。** 既省电，又天然避免了"界面在动但其实没新数据"的欺骗感。

节律数字的**唯一出处是 `PowerModel.cadence(popoverOpen:)`**，主轮询 / 能耗扫描都读它。
不在调用点各写一套 —— 改了其中一处就会悄悄不一致，而「实际节律」与「文档里写的节律」
不一致是最难发现的能耗回归（`--perf` 的报告也读同一个出处，所以报告不会与真实行为脱节）。

### 数据降级链（应对私有字段失效）

```
PowerTelemetryData 存在？
  ├─ 是 → 采用 SystemPowerIn / SystemLoad / BatteryPower
  └─ 否（Intel / 未来版本改名）→ 退回 Voltage × Amperage 单点口径
       └─ 再失败 → 退回 pmset / system_profiler 解析（仅额定功率，标注"估算"）
```

UI 上对降级来源做明确标注，不要静默降级。

---

## 7. UI 设计

配套设计稿展示了完整弹窗。设计原则按中性、接近 Linear / Vercel 的取向：白底、发丝边框（0.5px）、状态色只落在字形与描边上，不使用大块填充。

### 菜单栏图标（对齐 Juicy）

Juicy 的菜单栏语言是 **[闪电] + [圆角描边药丸，内含数字]**，配色按状态走绿 / 橙 / 红三档。
本项目照此自绘（`UI/MenuBarIcon.swift`），不用 SF Symbol 直接填色 —— 模板图会被系统强制单色，
而这里要的正是**保留颜色**。

| 项 | 取值 |
|---|---|
| 药丸 | 实心状态色底 + 一圈更亮的外环 + **白色数字** |
| 数字字号 | 药丸高度的 0.62，等宽粗体 |
| 闪电 | **仅 `isCharging` 为真时显示**，自绘贝塞尔路径（不走 SF Symbol）。已充满、插电未充、纯电池供电都不画 —— 闪电是"正在充电"的语义，不是"插着电"的语义 |
| 三档配色 | 绿（充电中 / 已充满 / 电量健康）/ 橙（偏低、**有证据的**插电净放电）/ 红（≤10%）。「插电净放电」不是「净功率为负」——判据见 §15 |
| 浅色菜单栏 | 绿降到 `#00A32B`；深色菜单栏用 Juicy 原色 `#00D832` |
| 白字可读性 | 白字先描一层暗色再压白 —— Juicy 的白字读得清就靠这个 |

形态三档可切换（`AppSettings.MenuBarStyle`，见 §11.1）：
**电池指示器**（默认，药丸 + 右侧一段附加读数）/ **极简**（Juicy 原味，只留药丸）/
**仅标志**（一枚圆角方块 + 白闪电，`NSStatusItem.squareLength`，占地最小）。
附加读数另有四档可选（瓦数 / 电量百分比 / 剩余时长 / 不显示），只有「电池指示器」档才显示。
形态与大小由 `MenuBarIcon.render(for:style:tint:height:)` 统一渲染 —— 状态项与设置面板里的预览走同一个函数。

**不要设 `button.contentTintColor`** —— 它会把彩色图标重新抹成单色，绿色就没了。

### macOS 26 状态项落位：一个必须处理的坑（实测）

菜单栏上的图标"看不到"，绝大多数情况下**不是代码问题**。实测把这条链路拆清楚了：

在刘海机型（M5 MacBook Air / 1470×956 pt）上量到的分区：

| 区域 | 逻辑坐标 | 说明 |
|---|---|---|
| 刘海左侧可用区 | x 0 – 646 | 应用菜单 + **状态项溢出隐藏区** |
| 刘海本体 | x 646 – 825（179 pt） | 不可用 |
| 刘海右侧可用区 | x 825 – 1470（645 pt） | 第三方项 + 系统项 |

**根因**：`NSStatusBar.system.statusItem(withLength:)` 新建的项会被系统追加到状态区**最左端**。
当状态区左端（实测 x≈887）已被挤到刘海边缘时，系统把新项塞进**刘海左侧区域**——
那里**不会被绘制**，但 API 一律返回"正常"：

| 观测项 | 隐藏时 | 正常时 |
|---|---|---|
| `statusItem.isVisible` | `true` | `true` |
| `button.title` / `button.image` | 均已正确设置 | 同 |
| `button.window.frame` | `(538, 923, 75, 33)` ← 刘海左侧 | `(1041, 923, 75, 33)` |
| `button.window.occlusionState.contains(.visible)` | **`false`** | **`true`** |

也就是说 `isVisible` 完全不可作为判据；**`occlusionState` 才是唯一可用信号**。

已排除的干扰项（都不是原因）：`killall SystemUIServer`（无效）、收紧
`NSStatusItemSpacing` 到 4（需重新登录才生效，且此处无效）、把项缩到最小宽度
（`squareLength` 仍隐藏）、`ControlCenter` 里有无隐藏开关（只有系统自己的项）。

**解法**：给项设 `autosaveName`，并在首次启动时**播种**系统认可的落位偏好。
只要 `NSStatusItem Preferred Position <autosaveName>` 这个键存在，系统就会把该项放进
刘海右侧可见区：

```swift
// 必须在 statusItem(withLength:) 之前写
UserDefaults.standard.set(200.0, forKey: "NSStatusItem Preferred Position Wattup")
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.autosaveName = "Wattup"
```

对照实验（可复现，2 轮一致）：删掉该键 → `frame.x = 538`、`visible = false`；
写入该键 → `frame.x = 1041`、`visible = true`。之后用户 ⌘-拖拽图标，系统会覆盖该值并记忆。

**推论**：这类工具在刘海机型上必须把"图标可能被系统藏掉"当成常态来处理——
提供仅图标形态降低占地、用 `occlusionState` 自检、并在首启时播种落位。

### 弹窗（宽 336 pt，自上而下）

版式参考 Juicy：**大号数字 + 环形/条形进度 + 图标芯片 + 大写微标签**，
浅色 / 深色两套自适应（跟随系统外观）。

1. **英雄卡**（常驻）：大号状态色电量数字（`contentTransition` 滚动）+ 「🔋 充电中」图标芯片；
   右上角两组大写微标签（距充满 / 健康度）；下方粗圆角进度条（充电时条内有流动高光）；
   底部一行「电量计每 60 秒刷新 · 采样于 N 秒前」
2. **洞察卡**（条件出现，琥珀左描边）：插电净放电 → 「适配器功率不够用」（判据见 §15）；
   已接电源但被充电上限按住 → 「已接电源，但在 N% 停住了」；数据降级 → 「功率来自推导口径」
3. **KPI 双瓦片**（常驻）：整机消耗、电池净功率，各带一条 sparkline 与跨度标注（如「近 12 分」）；
   点数不足时**显示「积累中…」而不是画一条假线**
4. **四个可折叠分区**（`UI/CollapsibleCard.swift`）：功率流向 / 电池 / 充电器 / 能耗排行。
   折叠后只留一行「图标 + 大写微标签 + 右侧当下值 + 旋转箭头」，展开状态按 id 存 `UserDefaults`
   - 功率流向：分段条 + 图标图例 + 恒等式文案（`PowerFlowData` 同时供折叠摘要与展开详图，口径唯一）
   - 电池：环形健康度（带动画 trim）+ 循环/容量明细 + 再一层的「更多电芯与充电数据」
   - 充电器：适配器图标 + 名称/厂商 + 实际输入 + 协商档位 + PD 档位表
   - 能耗排行：真实应用图标 + 细条形 + 右对齐读数，**按名次着色**（第一名绿、第二名橙、其余中性），
     避免整屏都在喊
   - 折叠摘要必须写**当下最有信息量的那个数**（如「健康 100% · 循环 17」「VirtualMachine 197 mW」），
     否则折叠就等于丢信息
5. **底部**：低电量模式开关 → 「设置…」（打开应用内设置面板）→ 整条大号「退出 Wattup」
   → 采样耗时与刷新次数。
   外观 / 提醒 / 阈值这些「设置一次就不常动」的项**全部移出弹窗**（见 §11.1）：
   弹窗是「看一眼」的地方，形态分段控件与系统设置深链留在这里只会把它撑成控制台。

#### 弹窗高度必须封顶在程序坞之上（实测）

原始需求是"全部展开时不要顶到程序坞，未展示的能下滑看"。只加 `ScrollView` 不够，
还得把**外框**算进去：

| 量 | 值（M5 Air / 1470×956） |
|---|---|
| 菜单栏条带 | y 923 – 956（33 pt） |
| 屏幕 `visibleFrame` | `(0, 50, 1470, 873)` ← 程序坞顶在 y = 50 |
| 状态项窗口 frame | `(1020, 923, 96, 33)` |
| **`NSPopover` 外框** | **26 pt**（实测：contentSize 855 → 真实窗口 881） |
| 可用内容高度 | 923 − 8 − 50 − 10 − **26** = **829 pt** |

```swift
let available = statusItemBottom - 8 - visible.minY - 10 - 26   // 8=箭头投影, 10=坞上留白
model.popoverBodyHeight = min(naturalContentHeight, available)
popover.contentSize = NSSize(width: 336, height: model.popoverBodyHeight)
```

内容自然高度用**另一个不带 `ScrollView` 的 `NSHostingController`** 量：
`ScrollView` 的 `fittingSize` 不可信。折叠/展开分区后 `contentRevision` 自增，
订阅它重新量一次。

#### 首屏高度必须稳定，不能依赖数据

默认只展开「功率流向」，其余三个折叠，首屏恒定 **741 pt**（< 829 pt），
无论数据怎么变都能完整显示到退出按钮。

不默认展开「能耗排行」的原因不是省地方：它的行数由数据决定（基线建立后 0–5 行），
展开时自然高度在 807 → 938 pt 之间漂 —— 那就变成"刚开机看着好好的，
过一会能耗基线建好了，弹窗自己开始滚动"。折叠后该行摘要仍给出第一名应用与读数。

#### 提示胶囊（`UI/StatusToast.swift`）

> 本节是旧版（左下角胶囊）的记录。当前实现已改为**屏幕正上方居中**，样式与延迟策略见 §11.2。

- 无边框 `NSPanel` + `[.borderless, .nonactivatingPanel]`，**不抢输入焦点**（插拔是后台事件）
- `level = .statusBar`、`collectionBehavior` 带 `.canJoinAllSpaces` / `.fullScreenAuxiliary`
- `hasShadow = false`，阴影交给 SwiftUI —— 透明无边框窗口的窗口级阴影会画出一个矩形
- **事件晚 1.4 秒才弹**：插上电源的瞬间功率读数还没稳定，
  抢那一两秒只会弹出一个 `0.0 W`；延迟后还要重新确认方向（防瞬时插拔）

### Juicy 色板（从官方界面图实测采样，见 `UI/Theme.swift`）

| 语义 | 深色（Juicy 原色） | 浅色（提高对比度） |
|---|---|---|
| 绿（主色） | `#00D832` | `#00B02E` / 文字 `#06812A` |
| 橙 | `#FF8A00` | `#C2710A` |
| 红 | `#FE0033` → 采用 `#FF453A` | `#D70015` |
| 卡片底 | `#1C2023` | `#FFFFFF` + 发丝描边 `#E6E6EB` |
| 进度条轨道 | `#2E3437` | `#E9E9EE` |

全部用 `NSColor.adaptive(light:dark:)` 动态构造，跟随系统外观切换。

### 必须出现在界面上的三句话

这三条是诚实性的落点，缺一条都会让产品退回到"看起来炫但不可靠"：

- 功率区标注 **「采样于 N 秒前」**（因为源数据 60 秒才更新）
- 排行区标注 **「覆盖当前用户进程，共 N 个，合计 X mW，占整机 Y W 的 Z%；系统守护进程不可读，仅用于相对比较」**
- 数据降级时**在对应字段旁标注来源**，不静默兜底（英雄卡下方的橙色提示行 + 洞察卡）
- 低电量模式写入失败时**直说系统限制**并打开「电池」设置，不做乐观赋值假装已切换
  （`LowPowerMode.writeDeniedExplanation`）

### 系统设置 / 电池 的深链（macOS 26 实测）

老的 `x-apple.systempreferences:com.apple.preference.battery` 在 macOS 26 上已失效。
现在电池面板属于 `PowerPreferences.appex`，正确 URL 是：

```
x-apple.systempreferences:com.apple.Battery-Settings.extension
```

（根页面仍是 `x-apple.systempreferences:`。两者都实测可直接打开对应面板。）

### P1 增补视图

- 历史曲线（功率 / 电量随时间，60 秒一个点）
- "为什么充得慢"诊断视图：把 `ChargerData.SlowChargingReason`、适配器 PD 档位、当前负载三者并列对比

---

## 8. 里程碑

### P0 · 可交付的只读监控（本方案全部已验证的子集）

- 三个采集器 + `PowerModel`（含恒等式交叉校验与降级链）
- 菜单栏图标 + 弹窗六个区块
- 应用能耗排行（差分法 + 用户归属过滤）
- 应用内设置面板（7 分栏）+ 顶部提示胶囊（插拔 + 三类告警）
- 中英文本地化、开机自启、无 Dock 图标
- 签名 + 公证 + Homebrew Cask 发布

**P0 的每一项都有实测数据支撑，不存在"待验证才能动工"的阻塞点。**

### P1 · 从监控走向诊断

- 历史曲线（SQLite 持久化）
- **告警已提前落地**（净放电 / 低电量 / 温度异常）：实现在应用内胶囊上，
  不走系统通知中心，因此不需要通知权限 —— 见 §11.2。P1 阶段要补的是"低充入功率"这一类诊断型提醒
- WidgetKit 桌面小组件
- "为什么充得慢"诊断视图

### P2 · 需要特权的能力

- 充电上限**控制**：需要 `SMAppService` 注册的 root daemon + XPC 通信 + SMC 写入。
  （**读取**已实现，见 §14 —— 读这个文件不需要任何权限，别把它一起推到 P2）
- **低电量模式切换**：`pmset -b lowpowermode` 需要 root。当前实现是"读得到 + 写不进"，
  失败时引导到「电池」设置。要真正一键切换，需要和上一条合用一个 root helper
- 反向供电监测（`PowerOutDetails`，本机当前未出现该字段，需在给其他设备供电时复测）

P2 的每项都是独立的风险面，建议单独评估，不要混进 P0/P1。

---

## 9. 风险与取舍

| 风险 | 影响 | 应对 |
|---|---|---|
| 私有字段无契约（`PowerTelemetryData` / `ChargerData` / `BatteryData`） | macOS 版本升级后字段改名或消失 | 三层降级链 + UI 标注来源；把字段探测做成启动自检 |
| 60 秒刷新率 vs "实时"预期 | 用户觉得"数字不动，是不是坏了" | UI 明示采样时间；用插值动画平滑但诚实标注 |
| 能耗排行只覆盖 8% 且仅同 uid | 用户误以为加起来应等于整机功耗 | 界面常驻说明；用"相对占比"而非"绝对瓦数"呈现 |
| 不进 MAS | 失去分发渠道与信任背书 | Homebrew Cask + 独立站；考虑开源 |
| 沙盒行为未验证 | 若未来要上 MAS 需重做排行 | 已按最坏情况设计，架构上把 `ProcessEnergySampler` 做成可摘除模块 |
| 不监控系统守护进程 | 无法解释部分功耗去向 | 在排行里显式列出"未覆盖的进程数"，而不是隐藏 |

---

## 10. 参考实现

| 项目 | 类型 | 可借鉴点 |
|---|---|---|
| **Juicy** | 商业，$14.99 买断 | Power Flow 动画的叙事方式、应用耗电视图、充电限制 |
| **PowerTop** | 开源，SwiftUI | **形态最接近目标**：功率流向图、瞬时功率、电芯数据、生命周期统计、双语、无 Dock 图标；明确仅支持带电池的 Apple Silicon 机型 |
| **Powerflow** | 开源（MIT），Tauri + Rust + Vue + Tailwind | `crates/tpower` 用 Rust 读 IOKit，可参考其字段封装方式 |
| **Stats** | 开源（MIT） | 模块化菜单栏架构、多模块共存方式 |
| **AlDente** | 早期开源，现闭源 | SMC 充电控制的实现路径；注意其当前版本已非开源 |
| **Battery Toolkit** | 开源 | Apple Silicon 充电上限（SMC）+ 非签名 helper 的取舍 |

技术参考：`ioreg` 字段解析与 `PowerTelemetryData` 三字段语义（`SystemPowerIn` = 进入主板的 DC 功率、`SystemLoad` = 主板+SoC+显示+外设总消耗、`BatteryPower` = 进出电池的净功率）。

---

## 11. 应用内设置面板与顶部提示胶囊

弹窗不再承担「控制台」职责：外观、提醒、阈值这些一次性设定全部收进独立设置窗口，
弹窗底部只留一枚「设置…」入口。提示胶囊改为**屏幕正上方居中**，对齐 Juicy。

### 11.1 设置面板结构

分栏对齐 Juicy 的图标分组（7 栏，`SettingsPane`）：

| 组 | 分栏 | 内容 |
|---|---|---|
| — | 通用 | 开机自动启动（`SMAppService.mainApp` 真实状态）、**通知外观**（提醒气泡尺寸 / 屏幕边缘光晕 / 实时预览 + 试弹）、最近采样耗时、恢复默认 |
| — | 提醒 | 插拔提示开关 + 停留时长；电量偏低 / 适配器功率不足 / 电池高温 三个告警 + 各自阈值 |
| — | 菜单栏 | 图标形态（电池指示器 / 极简 / 仅标志）＋ 附加读数（瓦数 / 百分比 / 剩余时长 / 不显示）＋ 配色档位（自动 / 浅 / 深）＋ 大小（小 / 默认 / 大）＋ 状态颜色开关 ＋ 实时预览 |
| — | 充电 | 低电量模式开关（写入失败时如实说明并给出系统电池面板入口）、充电上限（标注「规划中」） |
| 测量 | App 用量 | 排行条数、能耗采样窗口、跨 uid 权限边界说明 |
| 测量 | 电池 | 只读实时数据：电量 / 温度 / 健康度 / 循环 / 满充与设计容量 / 主板侧输入 / 电芯电压 |
| Wattup | 关于 | 版本、四类数据来源、四条已知限制、系统面板入口与退出 |

设计上的两条取舍：

1. **不做点了没反应的开关。** 充电上限**改写**需要 root helper 写 SMC，所以只呈现为只读状态（策略 / 停止充电电量 / 读取时间）并给出系统面板入口，而不是给一个假开关。「只读」这件事本身不需要任何权限，见 §14。
2. **状态颜色关闭后的行为写进副标题**（保留中性色，仅在电量极低时变红），因为这是用户唯一能从图标上看出差异的地方。

设置模型 `AppSettings`（`@MainActor`，`static let shared`）直接读写 `UserDefaults`，
每个 `@Published` 的 `didSet` 显式写自己那个键 —— 不做类型反射反查键名（那样又脆又难查）。
旧版 `menuBarDisplayMode`（wattage / percentage / iconOnly）在 `init()` 里做一次迁移，
映射到新的三档形态；旧键保留但不删，避免用户回退版本后设置全丢。

菜单栏图标渲染统一收口到 `MenuBarIcon.render(for:style:tint:height:)`，
状态项与设置面板里的预览走**同一个函数**，否则两处各画一套必然长得不一样。
配色同理：`MenuBarTint.color(for:isDark:statusColors:)` 是纯函数版本，
自检脚本在没有设置单例时也能直接调。

### 11.2 顶部提示胶囊

`StatusToastController` 用无边框 `NSPanel` 承载 SwiftUI 胶囊，关键点：

| 项 | 取值 | 理由 |
|---|---|---|
| 样式掩码 | `[.borderless, .nonactivatingPanel]` | 插拔 / 告警都是后台事件，弹提示不能把用户正在打的字顶掉 |
| 位置 | `y = screen.visibleFrame.maxY − h − 6` | `visibleFrame` 已排除菜单栏，用 `frame.maxY` 会盖住菜单栏图标 |
| 窗口阴影 | `hasShadow = false` | 窗口级阴影会画出一个矩形；阴影交给 SwiftUI（同色柔光 + 黑投影） |
| 集合行为 | `canJoinAllSpaces / fullScreenAuxiliary / transient / ignoresCycle` | 全屏空间里也要能出现，且不进 ⌘-Tab 循环 |

胶囊内容刻意做窄：色块图标 + 白粗标题 + 灰副标题，**不放进度条也不放右侧大号数字**。
顶部居中的组件是「扫一眼就走」的，信息层级一多就变成一块需要阅读的面板。

提示分两类，**延迟策略不同**：

- **插拔**：晚 1.4 秒再弹，且延迟后要重新确认方向。插上电源的瞬间功率读数还没稳定，
  抢那一两秒只会弹出一个 `0.0 W`；1.4 秒里状态也可能又翻回去（瞬时插拔 / 接触不良）。
  **插电这一路还要再多等一件事：`IsCharging` 翻身**（见下）。
- **告警**（低电量 / 适配器功率不足 / 电池高温）：立即弹。同时**每类每次启动只弹一次**
  （`firedAlerts: Set<ToastKind>` 去重），否则电量在阈值附近抖动时会反复刷屏。
  冷启动前 3 秒不判 —— 那时温度与功率读数还没稳定。

#### 插电提示为什么要等 `IsCharging`（而不是固定 1.4 秒）

**症状**：插上充电器，提示写「已接电源 · 未在充电 · 当前 45%」，过一会儿才变成「正在充电」。

**成因**是两件事叠在一起，都跟「读数比事件慢」有关：

1. `ExternalConnected` 是**物理存在**，插上就立刻为真；
   而 `IsCharging` 要等 PD 协商 + 系统决定充不充（还要看充电上限、温度），
   实测要**几秒**才翻过来。这两件事不同时发生。
2. 提示在 1.4 秒后就弹，而**主循环在弹窗关闭时是 5 秒一拍** ——
   1.4 秒那一刻手里的快照还是插电事件那一拍（`isCharging = false`）。
   于是提示报告的其实是一个「几秒前的真实状态」，正好落在用户最关心结论的那一刻。

**修法**（`AppDelegate.schedulePlugToast` + `PowerModel.refreshNow`）：

- 插电这一路在 1.4 秒之后**继续等到 `IsCharging || isFullyCharged`**，上限 4 秒；翻到就立刻弹，不傻等满。
- 等的过程里不等主循环 —— 每 400 ms 调一次 `PowerModel.refreshNow()` 主动插一拍
  （`refreshSnapshot` 的 `@MainActor` 串行保证不会和主循环打架）。
- 全程只发生在插电后的几秒内，**不改变常驻节律**（常驻仍 5 秒 / 弹窗打开 1 秒）。
- 拔电没有可等的事实（`IsCharging` 只会变 false），仍按固定 1.4 秒。
- 超时（例如被充电上限按住、根本不会开始充）就按当时的真实状态弹 ——
  这时文案会走下面那条，不再含糊。

配套的文案修正：接电但没在充时，**先看是不是被充电上限按住了**，
是就说「已到充电上限 · 当前 80%」，而不是笼统的「未在充电」（后者最容易被读成「没插好」）。
菜单栏 tooltip 的 `statusText` 同样区分「已接电源 · 已到充电上限」与「已接电源 · 未充电」。

低电量告警只在 `!isCharging` 时判，避免「边充边掉到 20%」误报。
「适配器功率不足」告警的五条判据见 §15 —— **正在充电 / 已充满时不报**，
系统按充电上限保电时的放电也不报，这两类都曾被误报成橙色。
提示走本应用自己的 `NSPanel`，**不经过系统通知中心**，因此不需要通知权限。

### 11.3 提醒外观：尺寸与光晕

外观档位与触发策略**解耦**：`提醒气泡尺寸` / `屏幕边缘光晕` 只决定长什么样，什么时候弹仍由「提醒」分栏的开关与阈值决定。
两项都放在「通用」分栏里（与 Juicy 的分区一致），因为它们改的是观感而不是提醒规则。

- 尺寸三档（紧凑 / 默认 / 宽松）的全部差异集中在 `ToastMetrics` 一个结构里（图标块、字号、内边距、圆角、描边、最小宽度），
  视图只读字段、不写死数值 —— 以后调档位不用碰 `StatusToastView` 的 body。
- 光晕按档位叠 1～2 层同色 `.shadow`（`EdgeGlow.halos`）。SwiftUI 的修饰器是类型级的、没法在循环里追加，
  所以层数写死成 0 / 1 / 2 三个分支。
- **画布要留够光晕的绘制余量**（`inset = max(档位自带下限, 光晕最大半径 + 8)`），
  否则柔光会被无边框面板的边界裁成一条直线。留出的这段 padding **不参与命中测试** ——
  点击手势挂在药丸本体上（`.contentShape(圆角矩形)` 写在 padding 之前），避免一圈看不见的区域顺手吞掉点击。
- 设置面板里的预览**渲染的就是真弹出来那套视图**，数据取当下读数（`ToastSpec.representative(from:)`），
  不存在「预览一套画法、实物另一套」。预览里的「显示光晕」开关只作用于那张图，
  让用户能在不动设置的前提下对照有 / 无光晕；标题里写明「（仅预览）」，免得被当成一个会落盘却没效果的开关。
- 「预览通知」按钮走 `StatusToastController.shared`：真面板、真定位、真停留时长。
  为此控制器改成单例 —— 两个控制器各持一块 `NSPanel`，两条提示会叠在同一位置打架。
- 预览舞台刻意不用纯白底（`SettingsStyle.previewStage`）：同色柔光落在纯白上几乎看不见，预览就失去了意义。

#### 屏幕边缘光带

「屏幕边缘光晕」这一个档位同时管两处观感，不另开一组设置：

1. 贴着药丸外缘扩散的一圈同色柔光（`EdgeGlow.halos`）。
2. **菜单栏正下方、横跨整屏的一条渐隐光带**（`ScreenEdgeGlowView`）—— 高度 `bandHeight` 关闭 / 默认 / 强烈 = 0 / 90 / 150 pt，
   峰值透明度 `bandAlpha` = 0 / 0.22 / 0.34。

光带的画法是竖向 `LinearGradient`（同色，`bandAlpha` → `bandAlpha × 0.55`）叠一层顶部居中的 `RadialGradient`
（`bandAlpha × 1.2` → 0，半径 520），外面再套一层 `.mask(LinearGradient(白 → 白 55% → 全透明, 从上到下))`。

两条不这样做就会出问题的约束：

- **必须单独一层 `NSPanel`**（`makeGlowPanel`，`level = .statusBar`、`ignoresMouseEvents = true`、`hasShadow = false`）。
  若图省事把胶囊那块面板撑成全屏宽，屏幕顶端就会多出一整条**不可点击的死区**。
- **`.mask` 是必需的**：`RadialGradient` 在带底仍残留约 1/4 透明度，屏幕上会横着切出一条硬边。套上 `.mask` 后竖向衰减只由 mask 决定，底行透明度严格到 0。

设置面板里的预览舞台同步改成 `ZStack(alignment: .top)`：150 pt 高的圆角舞台 + 顶部光带 + 下移 8 pt 的胶囊，整体裁进圆角，所见即所得。

### 11.4 自检与取证

新增 / 变更的入口：

```bash
$APP --settings [--settings-pane=menuBar|alerts|general|charging|usage|battery|about] \
               [--settings-shot=x.png]     # 打开设置面板并自渲染；可指定初始分栏
$APP --settings --settings-via-button      # 走弹窗「设置…」按钮那条无参入口，验证同一段代码
$APP --toast=plug|unplug|low|discharge|temp [--toast-shot=x.png] [--glow-shot=x.png]
                                                # 五种提示各自核版式 + 打印位置裁定（居中 / 未盖菜单栏 / 在坞之上）；
                                                # --glow-shot 另存屏幕边缘光带；光晕「关闭」档不建光带面板，会报 snapshot failed，属预期
                                                # 不给截图路径就在屏幕上真弹 6 秒，肉眼看位置
$APP --icon-strip=x.png --menubar=batteryIndicator|minimal|mark --appearance=light|dark
$APP --toast-strip=x.png --appearance=light|dark
                                                # 尺寸 × 光晕 九种组合画进一张图 —— 改外观档位时的主要证据
$APP --menubar=batteryIndicator|minimal|mark   # 兼容旧值 wattage|percentage|iconOnly
```

位置裁定的打印里包含光带四项：`frame` / `level` / `忽略鼠标` / `带窗口阴影`，
并给出 `✅ 贴着菜单栏下沿 / ✅ 横跨整屏 / ✅ 不吃点击` 三行判定。
光带默认档实测 `frame = (0, 833, 1470, 90)`、强烈档 `(0, 773, 1470, 150)`，`level = 25`（`.statusBar`）。

自渲染取证的两条已知边界（实测）：

1. **自渲染截图里开关轨道偏灰。** 从后台 shell 启动时进程拿不到 active
   （`NSApp.isActive == false`，即使临时切 `.regular` 并 `activate(ignoringOtherApps:)`），
   非 key 窗口里 AppKit 把 `NSSwitch` 画成未激活的灰色轨道。
   **滑块位置仍然忠实反映绑定值** —— 用「改 UserDefaults 前后各渲一张做差分」可以确认这一点；
   开关的实际取值另看 `--verify-popover-fit` 打印的 `toastEnabled`。
2. **`--sections=` / `--settings-pane=` 只影响截图，`--menubar=` 才是真正的临时覆盖**
   （后者走 `transientStyle`，不落 UserDefaults）。`--sections=` 会写盘，截完要 `--sections=reset`。
3. **`--icon-strip` 分不出「电池指示器」与「极简」**：两档画的都是同一个药丸，
   差别只在药丸右侧那段附加读数，而对照图不画附加读数 —— 两张图逐像素相同（md5 一致，实测）。
   要核对附加读数就去看真实状态项的 `button.title`（`--verify-statusitem`）或设置面板里的预览。

---

## 12. 自身能耗（本工具跑在别人的电池上，必须自己省）

### 起因

一个 7×24 常驻的菜单栏工具，「自己花多少电」和「功能对不对」同等重要。
优化的顺序是**先量 → 再改 → 再量**，不靠读代码猜。

### 量：`--perf` 把开销拆到阶段

`--perf` 把每个阶段按真实代码路径单独计时，再乘各自节律折算成「每小时 CPU 毫秒」。
菜单栏工具的能耗几乎就是「固定成本 × 频率」，只看一个总量无从下手。

优化前（弹窗关闭常态，即 99.9% 的时间）：

| 阶段 | ms/次 | 次/时 | ms/时 | 占比 |
|---|---|---|---|---|
| 低电量模式读取（起 `pmset` 子进程） | 73.8 | 60 | **4429** | **83%** |
| 全进程能耗扫描 | 4.06 | 120 | 487 | 9% |
| 每轮询周期固定成本（7 项） | 0.544 | 720 | 392 | 7% |
| **合计** | | | **5308** | |

**第一眼以为大头是「每 5 秒一次」的轮询，量出来才发现是「每 60 秒一次的子进程」。**
一次性的固定成本（起进程）远大于高频但极廉价的 IORegistry 读取（0.29 ms）。

### 改：三处

1. **`pmset` 子进程 → 进程内公开 API。**
   `pmset -g` 实测 82.8 ms/次（fork + exec + dyld 加载 pmset 及其 IOKit 依赖）；
   `ProcessInfo.isLowPowerModeEnabled` 实测 < 0.001 ms，读数一致（`--lpm` 并排打印两者供复核）。
   再挂 `NSProcessInfoPowerStateDidChange` → 周期归零。**「不问」优于「问得更便宜」。**

2. **状态项按「渲染签名」门控重绘。**
   签名 = 形态 / 图标尺寸 / 明暗 / 状态色开关 / 电量 / 充电 / 外接 / 净放电 / 附加读数 / tooltip。
   电量计 60 秒才更新一次而主轮询 5 秒一次 → 原先 12 次重绘里 11 次在重画相同像素。
   实测单次 0.124 ms → 0.005 ms。
   注意 tooltip 也必须进签名：`statusText`（如「正在充电」→「已充满」）变化时菜单栏像素不变，
   只放「看起来相关」的几个字段会让提示文字变成陈旧值。

3. **展示专用指标在无界面可见时不写。**
   `secondsSinceGaugeUpdate` 是每秒都在变的派生值，每轮写它 = 每轮触发一次
   `objectWillChange` → 整棵视图树重算 body。判据是「弹窗 / 预览窗口 / 设置面板任一可见」，
   用**闭包从 AppDelegate 拉取**而不是发通知推状态 —— 拉取永远与真实可见性一致。
   （`--ui-preview` 用的是独立窗口而非弹窗，只判 `popover.isShown` 会让预览截图读到陈旧值。）

顺带：能耗扫描原先在枚举 550 个进程时挨个解析可执行路径（`proc_pidpath` 每次最多拷 1024 字节），
而绝大多数进程两次扫描之间没有能耗增量。改成**先确认有增量、再解析身份**后，扫描 ~4–5 ms → ~3 ms。

### 再量：受控 A/B

直接测「当前运行的实例」不可靠：弹窗开与不开，轮询差 5 倍、扫描差 30 倍，同一份二进制能差好几倍。
`docs/probe/ab_energy.sh` 自己拉起进程、静置 15 秒、弹窗保持关闭、各测多轮：

| 指标（每 60 秒窗口） | 优化前 | 优化后 |
|---|---|---|
| **空闲唤醒次数** | **14 – 15 次** | **2 次** |
| CPU 时间 | 9.7 – 60.2 ms（波动极大） | 3.5 – 4.3 ms（稳定） |
| 平均功率 | 6.8 – 54.2 mW（波动极大） | 1.4 – 2.8 mW |
| `--perf` 折算同步开销 | 5308 ms/时 | 494 – 591 ms/时 |

- **优化前的波动本身就是问题**：成本集中在「每 60 秒起一个子进程」的突发上，
  而突发比等量但均匀的消耗更伤续航 —— 每次都要把 CPU 从深空闲态拉出来。
- **空闲唤醒次数是最可信的一项**：两轮 A/B 完全一致（14/15 → 2/2），
  它也是决定笔记本待机功耗的关键量。
- **绝对功率（mW）只能在同一轮 A/B 内部比较，不要当规格引用。** 后来在**同一份产物**上
  跨时段复测了四次：60 秒窗口 `1.096 / 6.062 / 5.913` mW，180 秒窗口 `5.514` mW；
  同期 CPU 占比 `0.007 – 0.014 %`、空闲唤醒 `2 – 6.7` 次/分。原因是 `ri_energy_nj`
  包含唤醒以及「把 SoC 拉出深空闲态」的代价，机器同期在干什么会显著改变读数。
  **稳态可对外引用的口径是 CPU 占用（~0.01%）与空闲唤醒次数，不是 mW。**

### 防回归

改完轮询 / 采样逻辑后跑 `--perf` 与 `docs/probe/ab_energy.sh`。
`--perf` 的节律数字读 `PowerModel.cadence`，所以报告不会与真实行为脱节。

---

## 13. 自检的「图标可见性」判定（别把锁屏误报成缺陷）

### 踩的坑

优化收尾时跑 `--verify-statusitem`，拿到 `occlusionState.visible: false` 且
「菜单栏 layer=25 窗口总数: 0」——看上去就是那个熟悉的「图标被藏进刘海左侧」。
差点又去改覆盖区 / `autosaveName` 落位逻辑。

**实际原因是屏幕锁着。** 判据：`lsappinfo front` 显示前台应用是 `com.apple.loginwindow`。
锁屏 / 显示器休眠 / 屏保期间**整条菜单栏都不绘制**，所以：

| 观测量 | 锁屏时 | 屏幕正常但图标被藏时 |
|---|---|---|
| `button.window.occlusionState.visible` | `false` | `false` |
| 菜单栏 `layer=25` 窗口数 | `0` | > 0（别人的图标都在） |
| `button.window.frame.minX` | 仍可读 | 仍可读 |

两个常用信号在锁屏时都会退化成同一个值，**单看它们无法区分这两种情况**。

### 解法

1. **新增 `Samplers/SessionState.swift`** 做「菜单栏此刻画不画」的判据：
   `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`（锁屏）、
   `CGDisplayIsAsleep(CGMainDisplayID())`（显示器休眠）、
   `com.apple.ScreenSaver.Engine` 是否在跑（屏保）。三者任一成立 → 不绘制。
   三个 API 都是公开的、不需要权限，实测在锁屏状态下全部返回预期值。
2. **判定抽成纯函数 `StatusItemVerdict.evaluate`**，三条分支各有明确文案：
   `○` 屏幕未亮 → 无法判定（不是缺陷）／`✓` 可见 ／`✗` 屏幕正常却不可见（真缺陷，附排查顺序）。
3. **补一条不依赖屏幕亮度的静态证据**：`window.frame.minX` 在锁屏时照样可读，
   拿它和 `screen.auxiliaryTopRightArea.minX`（刘海右侧可用区起点）比，
   就能在锁屏状态下仍然断言「落位参数正确」。
   实测：锁屏时 `x=1001.0 ≥ 825.0` → 落位正确；此时结论是「○ 无法判定全部可见性，但落位参数正确」。
4. **加 `--selfcheck-statusitem-verdict`**：锁屏期间真机只能覆盖三分支中的第一条，
   这个入口把三条都跑一遍并断言结论前缀，防止判定逻辑本身悄悄退化。

### 实测

```
$APP --selfcheck-statusitem-verdict   # 三条分支全部符合预期，exit=0
$APP --verify-statusitem              # 锁屏下 → ○ 无法判定 + 静态证据「落位参数正确」
                                      # 不再输出 ✗ 缺陷
```

---

## 14. 系统充电策略：能读，不能写

### 起因

真实提问：「为什么 Mac 充电到 80% 就不再充电了」。答案是 macOS 的**优化电池充电**，
不是故障。但"知道答案"和"让用户在界面里看到答案"是两件事。

原先设置面板里写的是「充电上限 · 规划中」，理由是**写入需要 root**。
这个理由对写入成立，对**读取**不成立 —— 于是这条理由把一件本来现在就能做的事推到了 P2。

### 数据源与权限

| 项 | 值 |
|---|---|
| 路径 | `/Library/Preferences/com.apple.powerd.charging.plist` |
| 权限 | `-rw-r--r-- root:wheel` —— root 可写，**全局可读** |
| 体积 | 690 字节 |
| `policies` 的值 | 一段 `NSKeyedArchiver` 归档（`Data`），不是普通 plist 字典 |

归档结构（实测 macOS 26.6.2 / Apple M5）：

```text
$objects[2] = { '$class': UID(6),          # ChargeCtrlPolicy
                'reason': UID(3),          # → $objects[3]，对象引用
                'soclimit': 80,            # 内联标量
                'drain': True, 'noChargeToFull': False,
                'isEndOfCharge': False, 'terminated': False,
                'owner': 32214,            # 活进程 pid，两次读数会变
                'token': UID(4) }
$objects[3] = 'optimizedBatteryCharging'
```

### 踩的坑：`NSKeyedUnarchiver` 只解 UID 值

一开始想用 `NSKeyedUnarchiver` + 一个 `NSCoding` shim 把整个策略对象解出来。
结果是**一半成功**：

```
reason: contains=true  obj=Optional(optimizedBatteryCharging)  int=0  bool=false
soclimit: contains=true  obj=nil  int=0  bool=false     ← 明明 contains 为 true
drain: contains=true  obj=nil  int=0  bool=false
owner: contains=true  obj=nil  int=0  bool=false
```

`containsValue(forKey:)` 全为 `true`，但除 `reason` 之外一律取不到值。
对照 Python `plistlib` 读同一个文件，所有字段都正常 —— 说明问题不在文件，在解码器。

根因：这个归档把**对象引用写成 UID、把标量内联写在对象字典里**。
`NSKeyedUnarchiver` 的 keyed 容器只把 UID 形式的值填进它的 `_values` 表，
遇到内联标量就给默认值（`nil`／`0`／`false`）。而 `reason` 恰好是 UID，所以只有它活着。

（顺带排除的两条路：`CFKeyedArchiverUIDGetValue` 是私有符号，链接不过；
`Mirror(reflecting:)` 对 CF 类型返回 0 个子节点。）

### 解法：两条路读同一个 blob

| 字段 | 怎么读 |
|---|---|
| `soclimit` / `drain` / `owner` / … | `PropertyListSerialization` 展开 `$objects`，直接取内联标量 |
| `reason` | 它是 UID，用 `NSKeyedUnarchiver` + 只解 `reason` 的 shim（`@objc(WattupChargingReasonShim)`，嵌套类不显式命名编译不过） |

两条路读的是同一段 blob、同一个对象，不会读到不一致的快照。
策略对象用「带 `soclimit` 的字典」定位，而不是固定下标 —— `$objects` 的顺序由归档器决定，不是契约。

### 语义边界（界面必须守住）

**这个文件说的是系统被配置成要做什么，不是此刻正在做什么。** 由此分出两层：
`ChargingPolicy` 只承载配置，`isHoldingNow(_:)` 结合实时电量才回答"此刻"。

判定"此刻被按住"要三个事实同时成立：接着电源、**没有在充电**、电量已到停充点。
只看 `reason` 会把"插着电正往 100% 充"也报成"停住了"。

同理，「读不到」与「没有启用优化充电」是**两件不同的事**，文案必须分开；
`terminated` 的策略记录里仍留着 `soclimit`，所以要有 `effectiveSocLimit`，
否则会把一条已废弃的记录显示成"正在生效的上限"。
（这条是自检的分支覆盖抓出来的 —— 最初 `terminated` 被渲染成了「读不到」。）

### 调用节律

读一次 **0.099 ms**（20 次平均，含读文件 + 两次 plist 展开 + unarchive），
比一次电量计读取便宜。但仍按「不改就不问」处理：只在**有界面可见**时读，
节流 60 秒（与电量计刷新对齐，搭同一次唤醒）；插拔、打开弹窗这些确定时刻强制重读。
只在字段真的变了才写 `@Published`。

### 实测（真机，2026-09-30）

跑 `--selfcheck-charging-policy` 时机器恰好处于被按住的状态：

```
当前: 接电源=true  正在充电=false  电量=80%
✅ 此刻确实被策略按住（接电 + 未充电 + 电量 80% ≥ 停充点 80%）—— 与读到的策略一致
单次读取: 0.099 ms
```

这就是那个原始提问的现场取证：**策略与实时状态对上了**。

### 没验证的事

- 系统是否真的在按这条策略执行 —— 只能靠真机观察，代码无法自证；
- 手动「充电上限」所用的 `reason` 取值（本机未设置过，取不到样本），
  因此未收录的 `reason` **原样带出来展示**，不猜它的含义；
- `owner` 字段的确切含义（只知道它是活进程 pid）。

---

## 15. 「插电净放电」告警：从「净功率为负」改成「有证据的缺口」

**症状**：插上充电器，弹出的顶部提示与状态栏图标都是**橙色**（写着「适配器功率不足」），
而机器明明在充电、适配器也够用。只要插着就一直橙。

**旧判据**（一句话）：

```swift
isExternalConnected && batteryNetWatts < -0.1   // ← 就是它
```

`-0.1 W` 是量化噪声级（`Amperage` 的台阶 ±10 mA × 12.5 V ≈ ±0.13 W），
且**任何**插电时的电池倒灌都会命中它。而 macOS 在插电时主动让电池倒灌是常态。

### 实测证据（这台机器的系统日志）

`pmset -g log` 里同一电量下 AC / 电池来回切：

```
2026-10-03 10:03:23  Using AC(Charge: 86)
2026-10-03 10:03:29  Using Batt(Charge: 86)     ← 6 秒后就切走了
2026-10-03 10:04:13  Using AC(Charge: 86)
2026-10-03 10:04:49  Using Batt(Charge: 86)
```

适配器物理上挂着，系统却**定期切到纯电池供电**把电量放回充电上限（策略里 `drain = True`）。
那几个窗口里电池在净放电，**幅度就是整机负载**（本机实测 7 W 上下，比文档里
「20 W 充电器顶不住」的真实缺口 3.9 W 还大）——所以**这条误报靠调阈值修不掉**。

另一条成因是遥测块的刷新节律：`PowerTelemetryData` **60 秒才刷新一次**
（实测同一读数在 20 个采样点里纹丝不动，`UpdateTime` 也不变）。
插电后它可能还停在插电前那一拍，于是「上一拍在放电」被当成「此刻功率不够」。

### 现在的判据（五条同时成立才报警）

| # | 条件 | 挡掉什么 |
|---|---|---|
| 1 | `isExternalConnected` | 没插电的放电是正常的 |
| 2 | `!isCharging && !isFullyCharged` | **正在充电 / 已充满是正向状态**；与功率口径矛盾时不下结论 |
| 3 | `batteryNetWatts < -0.5 W` | 量化噪声；不再是 0.1 W |
| 4 | `!isHoldingAtChargeLimit` | 系统按充电上限保电时的放电是设计行为 |
| 5 | `SystemPowerIn > 0.5 W` | 适配器没被要求出力 → 电池放电是系统选择，构不成「功率不足」 |

第 2 条是最直接的一条，也是用户视角的那条：**「插上充电器、已经开始充电」不该是橙色。**
它在数据上是两个来源打架（电量计说 `IsCharging = true`，功率口径却算出净放电），
按本文件一贯的原则（来源矛盾时不下结论）什么都不该报。

第 4 条的输入 `isHoldingAtChargeLimit` **不在 IORegistry 里** ——
它来自 §14 那条策略（`ChargingPolicy.isHoldingNow`：接电 + 未充电 + 电量 ≥ 停充点），
由 `PowerModel.publish` 在发布前写进快照，好让颜色/文案这些纯函数视图不必持有模型。
读不到策略时按「没有保电」处理 —— 宁可多报一次，也不静默吞掉真实告警。

### 顺带修掉的一处荒谬值

插电后遥测还没刷新时 `SystemPowerIn = 0`，而电池已经在充电，
`systemLoadWatts` 的降级分支 `输入 − 电池` 会算出**负数**（实测 −26 W）。
整机消耗不可能是负的 → 改成返回 `nil`，界面显示「—」而不是一个看起来像数据的荒谬值。

### 回归

`--selfcheck-power-caliber` 从 6 条扩到 **11 条判定分支 + 3 条颜色断言**，
颜色断言直接比对**界面最终取到的色值**（不是中间布尔量）：

```
✅ 插电 · 正在充电（遥测还停在插电前那一拍）
     提示色 #00D832（绿）｜图标色 #00D832｜期望 绿
✅ 插电 · 按上限保电，系统切到电池放电
     提示色 #00D832（绿）｜图标色 #00D832｜期望 绿
✅ 插电 · 20 W 充电器真的顶不住（两套口径一致指向放电）
     提示色 #FF8A00｜图标色 #FF8A00（告警橙）｜期望 橙
```

**踩过的坑**：颜色断言第一版写成 `toastTint == JB.green`，全假红 ——
`JB` 里的令牌都是 `Color(nsColor: .adaptive(...))`，底层是**动态 NSColor**，
每次取到新实例，`Color ==` 比的是身份而不是数值。必须先解析到 sRGB 分量再比。

### 没验证的事

- 保电切到电池的那几秒里 `SystemPowerIn` 的真实读数（本次没抓到插电+保电的现场）。
  第 5 条判据依赖它；现场确认后会回来收紧或放宽。第 4 条已由系统日志实证，不依赖这个。

---

## 附录：复现命令

```bash
# 1. 一键看功率遥测（注意：嵌套字典内是无空格的 "SystemPowerIn"=18333）
ioreg -w0 -n AppleSmartBattery | grep -oE '"(SystemPowerIn|SystemLoad|BatteryPower|Amperage|Voltage)" ?= ?[0-9-]+'

# 1b. ⚠️ ExternalConnected / IsCharging / FullyCharged 是 **Yes/No 布尔值**，不是 1/0。
#     用 `= ?[0-9-]+` 去抓它们会静默匹配失败、拿到空值 —— 实测踩过：
#     探针把插着电的机器一直读成"未插电"，因为机器恰好没电时 0 看起来"对"。
ioreg -w0 -n AppleSmartBattery | grep -oE '"(ExternalConnected|IsCharging|FullyCharged)" ?= ?(Yes|No)'
# 另外 Amperage 在 ioreg 里按**无符号 64 位**打印（放电时是 1.8e19 那种大数），
# 要自己减 2^64 才是负数；App 侧走 CFNumber 所以本来就是对的，只有 shell/Python 探针要注意。

# 2. 适配器信息（额定功率是标称值，不是实际输出）
pmset -g ac
system_profiler SPPowerDataType | grep -A8 "AC Charger Information"

# 3. 公开 API 口径（与系统电池面板同源）
ioreg -c AppleSmartBattery -r | head -1

# 4. 进程能耗（需自行编译，见验证脚本）
#    proc_pid_rusage(pid, RUSAGE_INFO_V6, &ri) → ri.ri_energy_nj

# 5. 低电量模式（读得到，写不进 —— 需要 root）
pmset -g | awk '/lowpowermode/ {print $2}'
pmset -b lowpowermode 1   # → 'pmset' must be run as root...（exit=1）

# 6. 系统充电策略（只读，不需要 root；注意 policies 是 NSKeyedArchiver 归档而非普通字典）
ls -l /Library/Preferences/com.apple.powerd.charging.plist   # -rw-r--r-- root:wheel
plutil -p /Library/Preferences/com.apple.powerd.charging.plist | head -3
#   展开归档看 $objects（Python 侧最省事；Swift 侧见 §14 的两条路）
python3 -c "
import plistlib
d = plistlib.load(open('/Library/Preferences/com.apple.powerd.charging.plist','rb'))
o = plistlib.loads(d['policies'])['\$objects']
p = [x for x in o if isinstance(x, dict) and 'soclimit' in x][0]
print('reason =', o[p['reason']])          # UID 是 int 子类，直接当下标用
print({k: v for k, v in p.items() if k != '\$class'})
"
```

## 附录：应用自检入口（全部实测过）

```bash
APP=.build/Wattup.app/Contents/MacOS/Wattup

$APP --dump                                     # 打印解析结果，核对字段映射
$APP --verify-statusitem                        # 状态项是否真的落在菜单栏（occlusionState + 全部 layer=25 窗口）
                                                # 锁屏/显示器休眠/屏保时自判为「无法判定」并附静态落位证据，不误报缺陷
$APP --selfcheck-statusitem-verdict             # 状态项可见性判定的三条分支各跑一遍（不依赖屏幕是否点亮）
$APP --verify-popover                           # 合成点击 → 弹窗链路；打印真实窗口 frame 与 contentSize
$APP --verify-popover-fit [--sections=…]         # 内容自然高度 / 可用高度 / 预计窗口下沿 vs 程序坞顶；含当前外观设置
$APP --lpm                                      # 低电量模式自检：并排打印两种读法做交叉验证 + 写入被拒的行为
$APP --selfcheck-charging-policy                # 系统充电策略：文件权限 / 归档原始值 / 解析结果 / 重复读一致性 /
                                                # 七条文案分支 / 与实时电量状态对账 / 单次读取成本；末段列出「没验证的事」
$APP --perf [--perf-iters=N]                    # 采样开销分解：各阶段 ms/次，按节律折算成每小时 CPU 毫秒
$APP --selfcheck-power-event                    # 用合成快照验证插拔判定（首次不发 / 重复不发 / 翻转各发一次）
$APP --selfcheck-power-caliber                  # 功率口径仲裁 + 「插电净放电」告警门槛：
                                                # 11 条判定分支（含真机抓到的遥测说谎态、按上限保电的放电窗口）
                                                # + 3 条颜色断言，直接比对界面最终取到的色值（见 §15）
$APP --watch-power-events --watch-seconds=120   # 真机拔插验证：事件实时打到 stderr
$APP --icon-strip=x.png [--menubar=…] [--appearance=dark|light]
                                                # 五种状态的图标对照图（核对闪电只在充电时出现），跟当前形态/大小走
$APP --toast=plug|unplug|low|discharge|temp [--toast-shot=x.png]
                                                # 五种提示各自核版式 + 打印位置裁定（居中 / 未盖菜单栏 / 在坞之上）；
                                                # 不给截图路径就在屏幕上真弹 6 秒，肉眼看位置
$APP --settings [--settings-pane=…] [--settings-shot=x.png]      # 打开设置面板并自渲染截图
$APP --settings --settings-via-button           # 走弹窗「设置…」按钮那条无参入口
$APP --menubar=batteryIndicator|minimal|mark    # 临时覆盖形态（兼容旧值 wattage|percentage|iconOnly），不落盘
$APP --ui-preview --sections=all --warmup=50 --snapshot=x.png   # 整幅弹窗自渲染截图

# 分区展开预设：all / none / reset / flow,energy…（reset 用于还原出厂默认）
$APP --sections=reset
```

诊断入口的设计取向：**能自渲染就不截屏**（不依赖屏幕录制权限），
**能一次画全所有状态就不等真机状态变化**（`--icon-strip`）。
菜单栏图标的验证必须走"启动前后各截一张 + 差分定位"，因为本机装有 Juicy，
凭颜色认图标会把 Juicy 的渲染当成自己的。注意 `NSStatusBarWindow.windowNumber` 是哨兵值，
`screencapture -l` 对它不可用。

验证脚本（C / Swift）已在本机编译运行：

| 脚本 | 验证内容 |
|---|---|
| `energy_probe.c` | 能耗读取成功率与权限分布 |
| `uidprobe.c` | 权限边界是否等价于用户归属 |
| `energy_delta.c` / `sum.c` | 差分法有效性与四个计数器量纲标定 |
| `power_probe.swift` | IOKit 全字段读取 + 与公开 API 交叉验证 |
| `perf_probe.swift` | 采样耗时 + SMC 服务可达性 |
| `watch.swift` | 150 秒刷新节律观测 |
| `series.swift` | 逐秒采样与恒等式校验 |
| `pid_energy.c` | 单个常驻进程的能耗 / CPU / **空闲唤醒次数**（合成使用：`./pid_energy <pid\|名字> <秒数>`） |
| `ab_energy.sh` | 两个构建的受控 A/B（同条件、多轮、取最小值与中位数）—— 见 §12 |
