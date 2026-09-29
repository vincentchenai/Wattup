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

    /// 电池端净功率（W），正充负放
    var batteryNetWatts: Double? {
        if let mw = batteryPowerMW { return Double(mw) / 1000 }
        if let v = packVoltageMV, let i = packAmperageMA {
            return Double(v) * Double(i) / 1_000_000
        }
        return nil
    }

    /// 适配器实际输出功率（W）
    var systemInputWatts: Double? {
        systemPowerInMW.map { Double($0) / 1000 }
    }

    /// 整机消耗功率（W）
    var systemLoadWatts: Double? {
        systemLoadMW.map { Double($0) / 1000 }
    }

    /// 电池端功率（W），由电压电流算出的物理口径，用于交叉校验
    var packWattsFromVI: Double? {
        guard let v = packVoltageMV, let i = packAmperageMA else { return nil }
        return Double(v) * Double(i) / 1_000_000
    }

    /// 恒等式自检：遥测口径与物理口径的偏差（W）
    var identityDiscrepancyWatts: Double? {
        guard let a = batteryNetWatts, let b = packWattsFromVI else { return nil }
        return abs(a - b)
    }

    /// 插着电，但电池在净放电 —— 说明适配器功率不够用
    var isNetDischargingWhilePlugged: Bool {
        guard isExternalConnected, let w = batteryNetWatts else { return false }
        return w < -0.1
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
        if isExternalConnected { return "已接电源 · 未充电" }
        return "电池供电"
    }
}
