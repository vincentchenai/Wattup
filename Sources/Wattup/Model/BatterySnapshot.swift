import Foundation

/// 功率数据来自哪一层。UI 必须把这个来源显示出来，不做静默兜底。
enum TelemetrySource: String, Sendable {
    /// PowerTelemetryData 可用（Apple Silicon），能拿到适配器输入 / 系统负载 / 电池净功率
    case telemetry
    /// PowerTelemetryData 缺失，退回 Voltage × Amperage 的电池端单点口径
    case derived
    /// 无电池机型，只有适配器信息
    case adapterOnly
    /// 什么都读不到
    case unavailable

    var label: String {
        switch self {
        case .telemetry:   return "功率遥测"
        case .derived:     return "由电压 × 电流推导"
        case .adapterOnly: return "仅适配器信息"
        case .unavailable: return "数据不可用"
        }
    }

    var isDegraded: Bool {
        self != .telemetry
    }
}

struct PDOEntry: Sendable, Identifiable, Hashable {
    let voltageMV: Int
    let currentMA: Int

    var id: String { "\(voltageMV)-\(currentMA)" }
    var watts: Double { Double(voltageMV) * Double(currentMA) / 1_000_000 }
}

/// 一次采样的完整结果。全部为值类型，可安全跨线程传递。
struct BatterySnapshot: Sendable {
    var sampledAt = Date()

    // MARK: 电量与状态
    var hasBattery = false
    var percentage = 0
    var isCharging = false
    var isFullyCharged = false
    var isExternalConnected = false
    var isFinishingCharge = false

    /// 系统此刻是否正「按充电上限保电」——接电、没在充电、电量处在限值附近或之上。
    ///
    /// 这个事实**不在 IORegistry 里**，它来自 `/Library/Preferences/com.apple.powerd.charging.plist`
    /// 的解码结果（`ChargingPolicy`），由 `PowerModel` 判定后写进快照，
    /// 好让颜色/文案这些纯函数视图不必自己持有模型。
    /// 没有读到生效策略时保持 `false` —— **「读不到」按「没有保电」处理**，
    /// 宁可多报一次也不静默吞掉真实告警。
    var isHoldingAtChargeLimit = false
    /// 距离充满的分钟数
    var timeToFullMinutes: Int?
    /// 距离放完的分钟数
    var timeToEmptyMinutes: Int?
    var batteryHealth: String?
    var healthCondition: String?

    // MARK: 电池端（物理口径）
    var packVoltageMV: Int?
    /// 正 = 充电，负 = 放电
    var packAmperageMA: Int?
    var batteryPowerMW: Int?
    var cellVoltagesMV: [Int] = []
    /// 摄氏度
    var batteryTemperatureC: Double?

    // MARK: 遥测口径
    var systemPowerInMW: Int?
    var systemLoadMW: Int?
    var systemCurrentInMA: Int?
    var systemVoltageInMV: Int?
    var adapterEfficiencyLossMW: Int?
    var telemetrySource: TelemetrySource = .unavailable

    // MARK: 适配器
    var adapterName: String?
    var adapterManufacturer: String?
    var adapterRatedWatts: Int?
    var adapterNegotiatedVoltageMV: Int?
    var adapterNegotiatedCurrentMA: Int?
    var adapterPDOMenu: [PDOEntry] = []
    var adapterIsWireless = false

    // MARK: 充电目标与异常
    var chargingCurrentMA: Int?
    var chargingVoltageMV: Int?
    var notChargingReason: Int?
    var slowChargingReason: Int?

    // MARK: 健康与寿命
    var cycleCount: Int?
    var designCycleCount: Int?
    var designCapacityMAH: Int?
    var maxCapacityMAH: Int?
    var nominalCapacityMAH: Int?
    var weightRa: [Int] = []
    var lifetimeOperatingMinutes: Int?

    /// 电量计自身的更新时间（`UpdateTime`）。UI 刷新以它为准。
    var gaugeUpdateTime: Date?

    static let empty = BatterySnapshot()

    // MARK: 派生值

    /// 电池健康度。用当前满充容量 ÷ 设计容量，上限 100%（与系统「最大容量」口径一致）。
    var healthPercent: Double? {
        guard let max = maxCapacityMAH, let design = designCapacityMAH, design > 0 else { return nil }
        return min(100, Double(max) / Double(design) * 100)
    }

    /// 电池端净功率的**遥测口径**（W，正充负放），直接来自 `PowerTelemetryData.BatteryPower`。
    /// 只用于诊断与交叉校验 —— 界面请用仲裁过的 `batteryNetWatts`。
    var batteryNetWattsTelemetry: Double? {
        batteryPowerMW.map { Double($0) / 1000 }
    }

    /// 两套独立口径对「电池此刻在充还是在放」是否给出同一个答案。
    /// `nil` = 只有一套可用，无从核对（**不是**「一致」）。
    var batteryPowerIsCorroborated: Bool? {
        guard let t = batteryNetWattsTelemetry, let p = packWattsFromVI else { return nil }
        return (t < 0) == (p < 0)
    }

    /// 电池端净功率（W），正充负放。
    ///
    /// 优先取遥测口径，但当它与物理口径（`Voltage × Amperage`）**符号相反**时退回物理口径：
    /// 两套口径对"在充还是在放"给出相反答案，说明至少一套在这个状态下不可信，
    /// 那就不能拿它去下任何结论。
    ///
    /// 实测（macOS 26.6.2 / Apple M5）确实遇到过这种状态：遥测说电池在放电 26.5 W，
    /// 而同一时刻 `IsCharging = Yes`、`Amperage = +2683 mA`（正 = 充）、
    /// `CurrentCapacity` 从 72% 爬到 74%、`pmset -g batt` 报 `charging; 1:02 remaining`
    /// —— 四条独立证据都指向"在充电"，是遥测那一套在说谎。
    /// 原先无脑采信遥测，于是刷出假的「插电净放电 / 适配器顶不住」，
    /// 并把状态栏图标与插电提示都染成橙色。
    var batteryNetWatts: Double? {
        let telemetry = batteryNetWattsTelemetry
        let physical = packWattsFromVI
        if let t = telemetry, let p = physical, (t < 0) != (p < 0) { return p }
        return telemetry ?? physical
    }

    /// 适配器实际输出功率（W）
    var systemInputWatts: Double? {
        systemPowerInMW.map { Double($0) / 1000 }
    }

    /// 整机消耗功率（W）。
    ///
    /// 正常情况直接取遥测的 `SystemLoad`。但当电池功率的两套口径互相矛盾时不能这么干：
    /// `SystemLoad` 与 `BatteryPower` 出自同一块遥测，实测两者满足
    /// `SystemLoad = SystemPowerIn − BatteryPower` —— 同一个符号错误会同时污染两者
    /// （实测那一状态：适配器 46.4 W、电池被报成 −26.5 W，于是"整机消耗"被算成 72.9 W，
    /// 而一台 M5 MacBook Air 在充电、适配器只送出 46 W 的情况下不可能真在吃 73 W）。
    /// 所以改由同一个恒等式、用两项可信值推算。
    var systemLoadWatts: Double? {
        if batteryPowerIsCorroborated == false,
           let input = systemInputWatts, let battery = batteryNetWatts {
            let derived = input - battery
            // 整机消耗**不可能是负的**。算出负值说明输入侧那一项本身就不可信 ——
            // 典型场景是插上电源后遥测块还没刷新（60 秒一拍），`SystemPowerIn` 仍是
            // 插电前的 0，而此时电池已经在充电，`0 − 正数` 就得到负数。
            // 宁可不给数（界面显示「—」），也不给一个荒谬值假装有数据。
            return derived >= 0 ? derived : nil
        }
        return systemLoadMW.map { Double($0) / 1000 }
    }

    /// 界面实际采用的口径。
    ///
    /// 遥测被判不可信（与物理口径符号相反）时按 `.derived` 对外展示 ——
    /// 这一层退化必须让用户看见，**不做静默兜底**。
    var effectiveTelemetrySource: TelemetrySource {
        (batteryPowerIsCorroborated == false && telemetrySource == .telemetry)
            ? .derived
            : telemetrySource
    }

    /// 遥测与物理口径打架，但**有正向状态背书** —— 矛盾是已解释的暂时现象。
    ///
    /// 「正在充电 / 已充满 / 被策略按住」是电量计给出的独立事实，它本身就是物理口径的旁证
    /// （充电中而物理口径指向放电，或反过来，在数据上不可能长期成立）。
    /// 此时遥测（`PowerTelemetryData`，60 秒一拍）多半还停在插电前那一拍 ——
    /// 实测用户视角：插上电源后整整一分钟，遥测说放电、电压 × 电流说充电，
    /// 界面于是挂着橙色的「功率来源降级」，洞察卡还错误地解释成"没有读到
    /// PowerTelemetryData"（其实读到了，是它还没跟上）。
    ///
    /// 这种情况下采信物理口径**不算降级**：电压与电流是电池端的直接测量，
    /// 不是从别的量推出来的近似值。UI 用它把橙色的「降级」呈现换成中性的说明。
    var telemetryMismatchExplained: Bool {
        batteryPowerIsCorroborated == false
            && (isCharging || isFullyCharged || isHoldingAtChargeLimit)
    }

    /// 电池端功率（W），由电压电流算出的物理口径，用于交叉校验
    var packWattsFromVI: Double? {
        guard let v = packVoltageMV, let i = packAmperageMA else { return nil }
        return Double(v) * Double(i) / 1_000_000
    }

    /// 恒等式自检：遥测口径与物理口径的偏差（W）。
    ///
    /// 刻意用**遥测原始值**而不是仲裁后的 `batteryNetWatts` ——
    /// 仲裁过的值在两套打架时等于物理口径，偏差会恒等于 0，
    /// 恰好把这个自检想暴露的问题藏起来。
    var identityDiscrepancyWatts: Double? {
        guard let a = batteryNetWattsTelemetry, let b = packWattsFromVI else { return nil }
        return abs(a - b)
    }

    /// 「插电净放电」判定成立的**下限幅度**（W）。
    ///
    /// 取 0.5 W 而不是 0.1 W：`Amperage` 的量化台阶（±10 mA × 约 12.5 V ≈ ±0.13 W）
    /// 已经和 0.1 W 同量级，再往下就是把量化噪声当结论。
    static let netDischargeAlarmFloorWatts = 0.5

    /// 认为「适配器确实在给整机供电」的下限（W）。
    ///
    /// 低于这个值说明适配器挂着但几乎不出力 —— 那种情况下电池放电是**系统主动**切过去的，
    /// 不是适配器不够（见 `isNetDischargingWhilePlugged` 的说明）。
    static let adapterSupplyingFloorWatts = 0.5

    /// 插着电，但电池在净放电 —— 这是「适配器功率不够用」的**唯一出口**：
    /// 状态栏图标颜色、英雄卡配色、插电提示配色、洞察卡、一次性告警全部由它派生。
    ///
    /// 成立需要以下几条**同时**满足，缺一不可：
    ///
    /// 1. 适配器物理上挂着（`isExternalConnected`）。
    /// 2. **电量计没有在报「正在充电」/「已充满」**。
    /// 3. 仲裁后的电池净功率为负，且幅度超过 `netDischargeAlarmFloorWatts`。
    /// 4. 系统不在按充电上限保电（`isHoldingAtChargeLimit`）。
    /// 5. **适配器确实在给整机供电**（`SystemPowerIn` 有实质读数）。
    ///
    /// 第 2 条是最直接的一条：「插上充电器、已经开始充电」是用户眼里的正向事件，
    /// 不该被染成橙色。而它在数据上是**两个来源互相打架** ——
    /// 电量计说 `IsCharging = true`，功率口径却算出净放电。
    /// 按本文件一贯的原则（来源矛盾时不下结论），这种时候什么都不该报。
    /// 实际踩到的成因是遥测块 **60 秒才刷新一次**：插电后它可能还停在插电前那一拍，
    /// 于是"上一拍在放电"被当成"此刻功率不够"。`IsCharging` 是电量计的即时事实，
    /// 用它把这一整类误报挡掉，比调阈值可靠。
    ///
    /// 第 4、5 条针对另一种误报：macOS 在「优化电池充电」按上限保电时会
    /// **定期切到纯电池供电**把电量放回限值 —— 系统日志里表现为同一电量下
    /// `Using AC` 与 `Using Batt` 交替出现（实测 86% 时 6 秒内来回切）。
    /// 那几个窗口里电池在净放电、幅度就是整机负载（可达十几瓦），
    /// 但适配器根本没被要求供电（`SystemPowerIn ≈ 0`）——
    /// **是系统主动做的选择，不是「适配器功率不够」**。
    ///
    /// 旧实现只看 `净功率 < -0.1 W`，于是上面两类都被报成「适配器顶不住」，
    /// 并把状态栏图标与插电提示一起染成橙色，且只要插着就一直橙。
    /// 这类误报靠调阈值修不掉：保电放电的幅度比真实缺口的幅度还大。
    var isNetDischargingWhilePlugged: Bool {
        guard isExternalConnected else { return false }

        // 正在充电 / 已充满都是正向状态，直接放行 —— 不参与"功率不足"的判定
        guard !isCharging, !isFullyCharged else { return false }

        guard let w = batteryNetWatts, w < -Self.netDischargeAlarmFloorWatts else { return false }

        // 系统正按充电上限保电 —— 放电是设计行为
        if isHoldingAtChargeLimit { return false }

        // 适配器没在供电 —— 电池放电是系统选择，不是适配器不够。
        // 读不到 SystemPowerIn 时按「无法证明适配器在出力」处理，不报警。
        guard let input = systemInputWatts, input > Self.adapterSupplyingFloorWatts else { return false }

        return true
    }

    /// 适配器输出与整机负载的差（W）。负数代表适配器顶不住。
    var adapterHeadroomWatts: Double? {
        guard let input = systemInputWatts, let load = systemLoadWatts else { return nil }
        return input - load
    }

    /// 距电量计上次更新过了多少秒
    var secondsSinceGaugeUpdate: Int? {
        guard let t = gaugeUpdateTime else { return nil }
        return max(0, Int(Date().timeIntervalSince(t)))
    }

    var statusText: String {
        if !hasBattery { return isExternalConnected ? "外接电源" : "无电池" }
        if isNetDischargingWhilePlugged { return "插电但净放电" }
        if isFullyCharged { return "已充满" }
        if isCharging { return "充电中" }
        if isExternalConnected {
            // 「已接电源 · 未充电」最常被读成「没插好」。被充电上限按住时直接说明白。
            return isHoldingAtChargeLimit ? "已接电源 · 已到充电上限" : "已接电源 · 未充电"
        }
        return "电池供电"
    }
}
