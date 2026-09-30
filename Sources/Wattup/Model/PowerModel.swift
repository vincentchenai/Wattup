import Foundation
import SwiftUI
import AppKit
import Combine

/// 状态聚合层。
///
/// 刷新策略（依据实测：`AppleSmartBattery` 的功率读数刷新周期为精确 60 秒）：
/// - 常驻每 5 秒读一次 IORegistry（0.29 ms），只有 `gaugeUpdateTime` 变化才发布新快照，
///   避免「界面在动但其实没有新数据」的欺骗感
/// - 电源插拔事件立即触发全量刷新
/// - 低电量模式改成事件驱动（`NSProcessInfoPowerStateDidChange`），不进轮询
/// - 应用能耗差分：弹窗打开时 2 秒一次，关闭时降到 60 秒一次（**只维持基线**，
///   60 秒与电量计刷新同拍，搭同一次唤醒）
/// - 只服务于界面展示的指标，在没有界面可见时不写入（见 `publishDisplayMetrics`）
@MainActor
final class PowerModel: ObservableObject {

    static let shared = PowerModel()

    /// 刷新节律。**这里是唯一出处** —— 主轮询与能耗扫描都读它，
    /// 不在各调用点各写一套数字（改了其中一处就会悄悄不一致，
    /// 而「实际节律」与「文档/自检里写的节律」不一致是最难发现的能耗回归）。
    /// `--perf` 的报告同样读它，所以报告不会与真实行为脱节。
    struct RefreshCadence {
        /// 主轮询间隔
        let pollSeconds: Double
        /// 全进程能耗扫描间隔
        let energyScanSeconds: Double
    }

    /// 低电量模式不在这里 —— 它已改成事件驱动（`NSProcessInfoPowerStateDidChange`），
    /// 没有周期，也就没有间隔可配。这正是最省的那一档：不问。
    ///
    /// 弹窗关闭时能耗扫描用 60 秒：排行只在弹窗里可见，关着的时候扫描的唯一作用是
    /// **维持基线**（否则一打开弹窗首轮扫描没有差分、会显示"积累中"）。
    /// 60 秒与电量计的刷新周期对齐，让这次扫描搭在同一次唤醒上，不用额外唤醒一次 CPU。
    static func cadence(popoverOpen: Bool) -> RefreshCadence {
        popoverOpen
            ? RefreshCadence(pollSeconds: 1, energyScanSeconds: 2)
            : RefreshCadence(pollSeconds: 5, energyScanSeconds: 60)
    }

    @Published private(set) var snapshot = BatterySnapshot.empty
    @Published private(set) var energy = EnergyScanResult()
    @Published private(set) var secondsSinceGaugeUpdate: Int?
    @Published private(set) var lastRefreshAt = Date()
    @Published private(set) var refreshCount = 0
    /// 最近一次采样的总耗时，用于界面上展示自身开销
    @Published private(set) var lastSampleDurationMS: Double = 0

    // MARK: 系统开关

    /// 低电量模式当前状态。
    ///
    /// 数据源是 `ProcessInfo.isLowPowerModeEnabled` —— 进程内公开 API，
    /// **实测 < 0.001 ms**，不需要权限也不会读不到，所以这里是非可选 `Bool`
    /// （早先用 `pmset -g` 时才有「读不到」这一支，那次改动见 `LowPowerMode` 的说明）。
    @Published private(set) var lowPowerMode: Bool = LowPowerMode.isEnabled()
    /// 写入失败时的说明文案，显示在开关下方
    @Published private(set) var lowPowerModeHint: String?

    // MARK: 系统充电策略（只读）

    /// 系统充电策略。`nil` = **读不到**，不表示"没有开启优化充电"。
    ///
    /// 只读：这个文件由 powerd 维护，读它不需要任何权限，改写才需要。
    /// 界面上因此呈现为状态而不是开关 —— 见 `SettingsWindow` 的充电分区。
    @Published private(set) var chargingPolicy: ChargingPolicy?

    /// 判断策略此刻是否正在生效所需的实时电量事实
    var chargingHoldContext: ChargingHoldContext {
        ChargingHoldContext(isExternalConnected: snapshot.isExternalConnected,
                            isCharging: snapshot.isCharging,
                            percentage: snapshot.percentage)
    }

    /// 策略的界面文案。纯映射，界面直接取用，不在视图里再写一套判断。
    var chargingPolicyText: ChargingPolicyDisplay.Text {
        ChargingPolicyDisplay.text(for: chargingPolicy, live: chargingHoldContext)
    }

    /// 策略此刻是否正把电量按在某个位置 —— 弹窗洞察卡用它决定要不要解释"为什么停在 80%"。
    var isChargingHeldByPolicy: Bool { holdingChargeLimit != nil }

    /// 若此刻正被策略按住，返回策略设定的停充点；否则 `nil`。
    ///
    /// 单独抽出来是为了让洞察卡拿到一个**值**而不是模型引用 ——
    /// `InsightSection.alert` 是 nonisolated 的纯函数，不该去碰 `@MainActor` 的模型。
    var holdingChargeLimit: Int? {
        guard let policy = chargingPolicy, policy.isHoldingNow(chargingHoldContext) else { return nil }
        return policy.effectiveSocLimit
    }

    /// 策略两次读取之间的最小间隔。
    ///
    /// 读一次约 0.3 ms（700 字节文件 + 两次 plist 展开 + 一次 unarchive），
    /// 便宜到能进轮询；但策略本身**极少变**（用户改设置、系统释放到 100%、插拔），
    /// 所以按"不改就不问"的原则：只在有界面可见时读，且至少间隔 60 秒 ——
    /// 与电量计的刷新周期对齐，搭同一次唤醒。
    /// 插拔、打开弹窗这类确定的时刻另有强制刷新，不必等这 60 秒。
    private static let chargingPolicyInterval: TimeInterval = 60
    private var lastChargingPolicyReadAt = Date.distantPast
    private var lastChargingPolicySignature: String?

    /// 读一次策略。`force = true` 时忽略节流。
    ///
    /// 只在**数值真的变了**才写 `@Published` —— 每次写入都会让整棵视图树失效，
    /// 而策略在绝大多数轮询里都是同一份内容。
    func refreshChargingPolicy(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastChargingPolicyReadAt) >= Self.chargingPolicyInterval else { return }
        lastChargingPolicyReadAt = now

        let fresh = ChargingPolicyReader.read()
        let signature = Self.signature(of: fresh)
        guard signature != lastChargingPolicySignature else { return }
        lastChargingPolicySignature = signature
        chargingPolicy = fresh
    }

    private static func signature(of policy: ChargingPolicy?) -> String {
        guard let policy else { return "nil" }
        return "\(policy.reason ?? "-")/\(policy.socLimit.map(String.init) ?? "-")"
            + "/\(policy.terminated)/\(policy.noChargeToFull)/\(policy.drain)"
    }

    // MARK: 弹窗尺寸与折叠

    /// 弹窗内容区高度。由 AppDelegate 按「内容自然高度」与「程序坞之上可用高度」取小后写入。
    @Published var popoverBodyHeight: CGFloat = 560
    /// 折叠/展开分区后自增，AppDelegate 订阅它重新量高度
    @Published private(set) var contentRevision = 0

    /// 需要弹提示时回调（插拔电源 / 三类告警）。延迟与去抖在 AppDelegate 里做。
    var onToast: ((ToastSpec) -> Void)?

    private var lastConnectedState: Bool?
    /// 本次启动已经发过的告警，避免在阈值附近反复弹
    private var firedAlerts: Set<ToastKind> = []
    private var startedAt = Date()

    /// 整机消耗的历史样本（W），供弹窗里的迷你曲线使用。
    /// 按固定 20 秒节律累积，与轮询频率解耦 —— 这样无论弹窗开着（1 秒采样）
    /// 还是关着（5 秒采样），曲线的横轴跨度都是稳定的。
    @Published private(set) var loadHistory: [Double] = []
    /// 电池净功率历史（W，正充负放）
    @Published private(set) var batteryHistory: [Double] = []

    private static let historyInterval: TimeInterval = 20
    private static let historyLimit = 90
    private var lastHistoryAt = Date.distantPast

    /// 曲线覆盖的时间跨度（分钟），给界面标注用
    var historySpanMinutes: Int {
        Int(Double(loadHistory.count) * Self.historyInterval / 60)
    }

    /// 弹窗是否打开 —— 决定轮询是否提速（弹窗里是实时读数，用户正盯着看）
    var isPopoverOpen = false

    /// 是否有**任何**界面正在展示数据（弹窗 / `--ui-preview` 预览窗 / 设置面板）。
    ///
    /// 由 AppDelegate 注入实现，而不是让模型自己去问窗口系统：模型不该知道有几个窗口、
    /// 分别属于谁。用闭包"拉"而不是发通知"推" —— 拉取永远和真实可见性一致，
    /// 通知则要维护"谁开了谁关了"的状态机，漏一条就永久偏移。
    ///
    /// 用途只有一个：决定 `publishDisplayMetrics` 要不要写【只服务于展示】的指标。
    var isAnySurfaceVisible: () -> Bool = { false }

    /// 每次刷新完成后回调，用于更新状态栏按钮
    var onUpdate: (() -> Void)?

    private let energySampler = ProcessEnergySampler()
    private let monitor = PowerSourceMonitor()
    private var loopTask: Task<Void, Never>?
    private var started = false

    private init() {}

    // MARK: - 开关与折叠

    /// 折叠/展开分区后调用，触发外层重新量高度
    func bumpContentRevision() { contentRevision += 1 }

    /// 切换低电量模式。
    ///
    /// 写入失败是**预期路径**而不是异常：`pmset -b lowpowermode` 需要 root，
    /// 第三方应用拿不到。失败时如实告知并把用户送到「电池」设置，不做静默兜底。
    func setLowPowerMode(_ enabled: Bool) {
        let ok = LowPowerMode.setEnabled(enabled)
        // 无论成败都回读一次真实状态，不靠乐观赋值骗自己
        lowPowerMode = LowPowerMode.isEnabled()
        if ok {            lowPowerModeHint = nil
        } else {
            lowPowerModeHint = LowPowerMode.writeDeniedExplanation
            if let url = URL(string: SettingsLink.battery) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 回读系统开关。
    ///
    /// 早先这里是「每 60 秒起一个 pmset 子进程」，实测每次 82.8 ms、独占全部采样开销的 83%。
    /// 现在改成**事件驱动**：系统在低电量模式或热压力等级变化时发
    /// `NSProcessInfoPowerStateDidChange`，收到才读 —— 读本身是进程内的，零成本。
    /// 「不改就不问」比「问得更便宜」更彻底。
    private func syncLowPowerMode() {
        let value = LowPowerMode.isEnabled()
        if value != lowPowerMode { lowPowerMode = value }
    }

    /// 自检：用一串合成快照喂给**真实的发布路径**，验证插拔判定。
    ///
    /// 覆盖三个容易写错的边界：首次采样不该发事件、状态没变不该重复发、每次翻转各发一次。
    /// 边界说清楚：「真实拔掉电源时系统会不会把 `isExternalConnected` 翻过来」属于系统行为，
    /// 不在本自检范围内 —— 那一条要靠 `--watch-power-events` 真机拔插验证。
    func selfCheckPowerEvents() -> [String] {
        var lines: [String] = []

        let savedHandler = onToast
        let savedSnapshot = snapshot
        let savedCount = refreshCount
        var received: [String] = []
        onToast = { spec in
            switch spec.kind {
            case .pluggedIn:  received.append("插电")
            case .unplugged:  received.append("拔电")
            default:          break
            }
        }

        func sample(_ plugged: Bool) -> BatterySnapshot {
            var s = BatterySnapshot()
            s.hasBattery = true
            s.isExternalConnected = plugged
            s.percentage = 80
            s.gaugeUpdateTime = Date()
            return s
        }

        lastConnectedState = nil        // 模拟冷启动
        publish(sample(true))           // ① 首次采样：只建基线
        publish(sample(true))           // ② 无变化：不应重复发
        publish(sample(false))          // ③ 拔电
        publish(sample(false))          // ④ 无变化
        publish(sample(true))           // ⑤ 插电

        lines.append("事件序列: \(received.isEmpty ? "（无）" : received.joined(separator: " → "))")
        lines.append(received == ["拔电", "插电"]
                     ? "✅ 判定正确：首次不发、重复不发、翻转各发一次"
                     : "❌ 判定错误：期望「拔电 → 插电」")

        onToast = savedHandler
        snapshot = savedSnapshot
        refreshCount = savedCount
        lastConnectedState = nil        // 复位，别把合成状态留给真实采样
        return lines
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        // 首屏就要有值：策略不会因为"等 60 秒再读"而少读一次，而是这一档本来就要读一次
        refreshChargingPolicy(force: true)

        monitor.start { [weak self] in
            Task { @MainActor in
                self?.handlePowerSourceChange()
            }
        }

        // 低电量模式 / 热压力等级变化由系统通知驱动，不再轮询
        NotificationCenter.default.addObserver(
            forName: LowPowerMode.powerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLowPowerMode() }
        }

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        monitor.stop()
        started = false
    }

    /// 弹窗打开：提高到 1 秒轮询 + 立即重扫能耗 + 立刻同步一次系统开关
    func popoverDidOpen() {
        isPopoverOpen = true
        syncLowPowerMode()
        Task { [weak self] in
            await self?.refreshSnapshot(forceEnergyScan: true)
        }
    }

    func popoverDidClose() {
        isPopoverOpen = false
    }

    // MARK: - 主循环

    private func runLoop() async {
        await refreshSnapshot(forceEnergyScan: true)

        while !Task.isCancelled {
            let interval = Self.cadence(popoverOpen: isPopoverOpen).pollSeconds
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            await refreshSnapshot(forceEnergyScan: false)
        }
    }

    private func handlePowerSourceChange() {
        Task { [weak self] in
            guard let self else { return }
            await self.energySampler.resetBaseline()
            self.energy = EnergyScanResult()
            // 插拔会改变策略的生效状态（按住的判据里有"接着电源"这一条），
            // 也可能让系统在释放/重新按住之间切换 —— 这一档不等节流，立刻重读
            self.refreshChargingPolicy(force: true)
            await self.refreshSnapshot(forceEnergyScan: true)
        }
    }

    // MARK: - 采样

    /// 只服务于界面展示的指标。
    ///
    /// **没有任何界面可见时不写** —— 没人看，而每次 `@Published` 写入都会触发 `objectWillChange`，
    /// 让整棵弹窗视图树失效并在下一帧重算 body。那是纯粹的浪费（弹窗每 5 秒重算一次
    /// 与每秒重算一次，用户看不到任何差别）。
    ///
    /// 注意判据是「有**任何**界面可见」而不是「弹窗打开」：`--ui-preview` 的预览窗口
    /// 和设置面板同样在展示这两个数值（"采样 N ms / 已刷新 N 次"），
    /// 只看弹窗会让那两处的截图与读数变成陈旧值。
    private func publishDisplayMetrics(sampleMS: Double, secondsSinceGauge: Int?) {
        guard isAnySurfaceVisible() else { return }
        if lastSampleDurationMS != sampleMS { lastSampleDurationMS = sampleMS }
        if secondsSinceGaugeUpdate != secondsSinceGauge { secondsSinceGaugeUpdate = secondsSinceGauge }
    }

    private func refreshSnapshot(forceEnergyScan: Bool) async {
        let start = Date()

        let registrySnapshot = await Task.detached(priority: .utility) {
            RegistrySampler.sample()
        }.value

        let powerInfo = await Task.detached(priority: .utility) {
            PowerSourceSampler.batteryInfo()
        }.value

        let adapterInfo = await Task.detached(priority: .utility) {
            PowerSourceSampler.adapterInfo()
        }.value

        guard var new = registrySnapshot else {
            // 无电池机型或读取失败
            var fallback = BatterySnapshot()
            fallback.sampledAt = Date()
            fallback.hasBattery = false
            fallback.isExternalConnected = adapterInfo != nil
            fallback.telemetrySource = adapterInfo != nil ? .adapterOnly : .unavailable
            apply(adapterInfo, to: &fallback)
            recordHistory(fallback)
            publish(fallback)
            publishDisplayMetrics(sampleMS: Date().timeIntervalSince(start) * 1000,
                                  secondsSinceGauge: fallback.secondsSinceGaugeUpdate)
            return
        }

        // 用公开 API 补齐私有字段里没有的信息
        if let info = powerInfo {
            new.batteryHealth = info.batteryHealth
            new.healthCondition = info.healthCondition
            new.isFinishingCharge = info.isFinishingCharge ?? false
            if new.designCycleCount == nil { new.designCycleCount = info.designCycleCount }
            if new.timeToFullMinutes == nil, new.isCharging { new.timeToFullMinutes = info.timeToFullMinutes }
            if new.timeToEmptyMinutes == nil, !new.isCharging { new.timeToEmptyMinutes = info.timeToEmptyMinutes }
            if new.maxCapacityMAH == nil, let mc = info.maxCapacity { new.nominalCapacityMAH = mc }
        }

        // 适配器信息以 IORegistry 为主，公开 API 作补充
        apply(adapterInfo, to: &new)

        recordHistory(new)
        publish(new)
        publishDisplayMetrics(sampleMS: Date().timeIntervalSince(start) * 1000,
                              secondsSinceGauge: new.secondsSinceGaugeUpdate)

        // 充电策略只在有人看的时候读 —— 它只服务于界面展示（设置面板的状态行、
        // 弹窗的洞察卡），没有任何界面可见时读它是纯浪费。节流在方法内部。
        if isAnySurfaceVisible() { refreshChargingPolicy() }

        // 能耗扫描。基线还没建立时用更短的间隔 —— 首次扫描只建基线不算增量，
        // 按常规的 30 秒间隔会让用户干等半分钟才看到排行。
        let steadyInterval = Self.cadence(popoverOpen: isPopoverOpen).energyScanSeconds
        let energyInterval = energy.isBaselineReady ? steadyInterval : 8
        let elapsedSinceLastScan = Date().timeIntervalSince(lastEnergyScanAt)
        if forceEnergyScan || elapsedSinceLastScan >= energyInterval {
            await refreshEnergy()
        }
    }

    private var lastEnergyScanAt = Date.distantPast

    /// 历史曲线采样。节律固定，与轮询频率解耦，免得弹窗一开曲线横轴就被压缩。
    private func recordHistory(_ s: BatterySnapshot) {
        let now = Date()
        guard now.timeIntervalSince(lastHistoryAt) >= Self.historyInterval else { return }
        lastHistoryAt = now

        if let load = s.systemLoadWatts {
            loadHistory.append(load)
            if loadHistory.count > Self.historyLimit { loadHistory.removeFirst() }
        }
        if let battery = s.batteryNetWatts {
            batteryHistory.append(battery)
            if batteryHistory.count > Self.historyLimit { batteryHistory.removeFirst() }
        }
    }

    private func refreshEnergy() async {
        lastEnergyScanAt = Date()
        let result = await energySampler.scan()
        // 首次扫描只是建立基线，不要用它覆盖已有数据
        if result.isBaselineReady || energy.apps.isEmpty {
            energy = result
        }
    }

    private func apply(_ adapter: PowerSourceSampler.AdapterInfo?, to snapshot: inout BatterySnapshot) {
        guard let adapter else { return }
        if snapshot.adapterName == nil { snapshot.adapterName = adapter.name }
        if snapshot.adapterManufacturer == nil { snapshot.adapterManufacturer = adapter.manufacturer }
        if snapshot.adapterRatedWatts == nil { snapshot.adapterRatedWatts = adapter.watts }
        if snapshot.adapterNegotiatedVoltageMV == nil { snapshot.adapterNegotiatedVoltageMV = adapter.negotiatedVoltageMV }
        if snapshot.adapterNegotiatedCurrentMA == nil { snapshot.adapterNegotiatedCurrentMA = adapter.negotiatedCurrentMA }
        if snapshot.adapterPDOMenu.isEmpty { snapshot.adapterPDOMenu = adapter.pdoMenu }
        if adapter.isWireless == true { snapshot.adapterIsWireless = true }
    }

    /// 只有电量计真的更新了才发布新快照
    private func publish(_ new: BatterySnapshot) {
        // 插拔检测放在 publish 里（而不是 refresh 的某一条分支上），
        // 保证「有电池」与「无电池机型」两条路径都能发出事件。
        // 判据用「上一次真实生效的连接状态」，不能用上一次**发布**的快照 ——
        // 电量计没变化时 publish 会跳过赋值，那个快照可能是旧的。
        if let last = lastConnectedState, last != new.isExternalConnected {
            emitPlugToast(pluggedIn: new.isExternalConnected, snapshot: new)
        }
        lastConnectedState = new.isExternalConnected

        let gaugeChanged = new.gaugeUpdateTime != snapshot.gaugeUpdateTime
        let significantChange =
            new.percentage != snapshot.percentage ||
            new.isCharging != snapshot.isCharging ||
            new.isExternalConnected != snapshot.isExternalConnected ||
            new.telemetrySource != snapshot.telemetrySource ||
            new.batteryPowerMW != snapshot.batteryPowerMW

        if gaugeChanged || significantChange || refreshCount == 0 {
            snapshot = new
            refreshCount += 1
            lastRefreshAt = Date()
        }

        // 注意不再无条件写 secondsSinceGaugeUpdate —— 那是个每秒都在变的派生值，
        // 无条件写等于「每轮轮询都让 SwiftUI 重算一次」，见 publishDisplayMetrics 的说明。
        // 低电量模式不在这里回读 —— 改成事件驱动了，见 syncLowPowerMode
        checkAlerts(new)
        onUpdate?()
    }

    // MARK: - 提示胶囊

    /// 插拔电源提示。方向已在调用点确认过，这里只管「开关 + 发出去」。
    private func emitPlugToast(pluggedIn: Bool, snapshot: BatterySnapshot) {
        guard AppSettings.shared.toastEnabled else { return }
        onToast?(ToastSpec(kind: pluggedIn ? .pluggedIn : .unplugged, snapshot: snapshot))
    }

    /// 一次性告警。同类告警本次启动只发一次 —— 阈值附近会反复穿越，不去重就会刷屏。
    private func emitAlert(_ kind: ToastKind, snapshot: BatterySnapshot) {
        guard !firedAlerts.contains(kind) else { return }
        firedAlerts.insert(kind)
        onToast?(ToastSpec(kind: kind, snapshot: snapshot))
    }

    /// 阈值类告警检测。冷启动前 3 秒不判 —— 那时温度与功率读数还没稳定。
    private func checkAlerts(_ s: BatterySnapshot) {
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        guard s.hasBattery else { return }
        let settings = AppSettings.shared

        // 低电量：只在没充电时算，否则「边充边掉到 20%」会误报
        if settings.lowBatteryAlert, !s.isCharging, s.percentage <= settings.lowBatteryThreshold {
            emitAlert(.lowBattery, snapshot: s)
        }
        if settings.netDischargeAlert, s.isNetDischargingWhilePlugged {
            emitAlert(.netDischarge, snapshot: s)
        }
        if settings.highTemperatureAlert,
           let temp = s.batteryTemperatureC, temp >= settings.highTemperatureThreshold {
            emitAlert(.highTemperature, snapshot: s)
        }
    }

    // MARK: - 给菜单栏图标用的展示值

    /// 无障碍描述（也给 tooltip 用）
    var menuBarText: String {
        var parts: [String] = []
        if snapshot.hasBattery { parts.append("\(snapshot.percentage)%") }
        parts.append(snapshot.statusText)
        if let w = snapshot.batteryNetWatts {
            parts.append("电池 \(String(format: "%.1fW", abs(w)))")
        }
        return parts.joined(separator: " ")
    }
}
