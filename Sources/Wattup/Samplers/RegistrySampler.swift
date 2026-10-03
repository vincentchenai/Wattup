import Foundation
import IOKit

/// 主数据源：`AppleSmartBattery` 的 IORegistry 属性。
///
/// 实测（MacBook Air M5 / macOS 26.6.2）：
/// - 全量属性读取 0.29 ms / 次，无需 root
/// - 其中 `PowerTelemetryData` 与 `ChargerData`、`BatteryData` 均为 Apple 私有字段，无公开契约，
///   因此所有取值都走可选路径，缺失时交由上层降级。
enum RegistrySampler {

    // MARK: - 原始读取

    static func readRawProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties,
                                               kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }

    // MARK: - 采样

    static func sample() -> BatterySnapshot? {
        guard let raw = readRawProperties() else { return nil }

        var s = BatterySnapshot()
        s.sampledAt = Date()
        s.hasBattery = (raw["BatteryInstalled"] as? Bool) ?? true

        // 电量与状态
        s.percentage = int(raw["CurrentCapacity"]) ?? 0
        s.isCharging = bool(raw["IsCharging"]) ?? false
        s.isFullyCharged = bool(raw["FullyCharged"]) ?? false
        s.isExternalConnected = bool(raw["ExternalConnected"]) ?? false
        s.timeToFullMinutes = minutes(raw["AvgTimeToFull"]) ?? minutes(raw["TimeRemaining"]).flatMap { s.isCharging ? $0 : nil }
        s.timeToEmptyMinutes = s.isCharging ? nil : minutes(raw["TimeRemaining"])

        // 电池端
        s.packVoltageMV = int(raw["Voltage"])
        s.packAmperageMA = int(raw["Amperage"]) ?? int(raw["InstantAmperage"])
        s.liveBatteryCurrentMA = SMCBatterySampler.currentMA()
        if let t = int(raw["Temperature"]), t > 0 { s.batteryTemperatureC = Double(t) / 100 }

        // 遥测口径
        var telemetryAvailable = false
        if let pt = raw["PowerTelemetryData"] as? [String: Any] {
            let powerIn = int(pt["SystemPowerIn"])
            let load = int(pt["SystemLoad"])
            let batt = int(pt["BatteryPower"])
            if powerIn != nil || load != nil || batt != nil {
                telemetryAvailable = true
            }
            s.systemPowerInMW = powerIn
            s.systemLoadMW = load
            s.batteryPowerMW = batt
            s.systemCurrentInMA = int(pt["SystemCurrentIn"])
            s.systemVoltageInMV = int(pt["SystemVoltageIn"])
            s.adapterEfficiencyLossMW = int(pt["AdapterEfficiencyLoss"])
        }

        // 降级链：遥测 -> 电压×电流 -> 不可用
        if telemetryAvailable {
            s.telemetrySource = .telemetry
        } else if s.packVoltageMV != nil && s.packAmperageMA != nil {
            s.telemetrySource = .derived
            s.batteryPowerMW = Int(Double(s.packVoltageMV!) * Double(s.packAmperageMA!) / 1000)
        } else if s.isExternalConnected {
            s.telemetrySource = .adapterOnly
        } else {
            s.telemetrySource = .unavailable
        }

        // 适配器
        if let ad = raw["AdapterDetails"] as? [String: Any] {
            s.adapterName = string(ad["Name"])
            s.adapterManufacturer = string(ad["Manufacturer"])
            s.adapterRatedWatts = int(ad["Watts"])
            s.adapterNegotiatedVoltageMV = int(ad["AdapterVoltage"])
            s.adapterNegotiatedCurrentMA = int(ad["Current"])
            s.adapterIsWireless = bool(ad["IsWireless"]) ?? false
            s.adapterPDOMenu = pdoMenu(ad["UsbHvcMenu"])
        }

        // 充电目标与异常原因
        if let cd = raw["ChargerData"] as? [String: Any] {
            s.chargingCurrentMA = int(cd["ChargingCurrent"])
            s.chargingVoltageMV = int(cd["ChargingVoltage"])
            s.notChargingReason = int(cd["NotChargingReason"])
            s.slowChargingReason = int(cd["SlowChargingReason"])
        }

        // 电池详情
        s.cycleCount = int(raw["CycleCount"])
        s.designCycleCount = int(raw["DesignCycleCount9C"])
        s.designCapacityMAH = int(raw["DesignCapacity"])
        s.maxCapacityMAH = int(raw["AppleRawMaxCapacity"])
        s.nominalCapacityMAH = int(raw["NominalChargeCapacity"])

        if let bd = raw["BatteryData"] as? [String: Any] {
            s.cellVoltagesMV = intArray(bd["CellVoltage"])
            s.weightRa = intArray(bd["WeightedRa"])
        }
        if let life = raw["LifetimeData"] as? [String: Any] {
            s.lifetimeOperatingMinutes = int(life["TotalOperatingTime"])
        }

        // 电量计刷新时间戳 —— UI 刷新以它为准
        if let ut = int(raw["UpdateTime"]), ut > 0 {
            s.gaugeUpdateTime = Date(timeIntervalSince1970: TimeInterval(ut))
        }

        return s
    }

    // MARK: - 取值辅助（IORegistry 里数值类型不统一，全部走宽松解析）

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let n = value as? NSNumber { return n.boolValue }
        if let b = value as? Bool { return b }
        if let s = value as? String { return (s as NSString).boolValue }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// `AvgTimeToFull` / `TimeRemaining` 里 65535 是「未知」哨兵值
    static func minutes(_ value: Any?) -> Int? {
        guard let v = int(value), v > 0, v < 65535 else { return nil }
        return v
    }

    static func intArray(_ value: Any?) -> [Int] {
        if let arr = value as? [NSNumber] { return arr.map(\.intValue) }
        if let arr = value as? [Int] { return arr }
        if let arr = value as? NSArray {
            return arr.compactMap { ($0 as? NSNumber)?.intValue }
        }
        return []
    }

    /// `UsbHvcMenu` = [{Index, MaxCurrent, MaxVoltage}, ...]
    static func pdoMenu(_ value: Any?) -> [PDOEntry] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let mv = int(item["MaxVoltage"]), let ma = int(item["MaxCurrent"]) else { return nil }
            return PDOEntry(voltageMV: mv, currentMA: ma)
        }
    }
}
