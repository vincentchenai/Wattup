import Foundation
import IOKit
import IOKit.ps

/// 公开 API 口径的数据源 —— 与系统电池面板同源。
///
/// 用途有二：
/// 1. 补齐 IORegistry 私有字段里没有的信息，例如 `BatteryHealth`（Good / Fair / Poor）
/// 2. 在私有字段失效时作为降级依据
///
/// 实测读取成本 0.061 ms / 次。
enum PowerSourceSampler {

    struct Info: Sendable {
        var currentCapacity: Int?
        var maxCapacity: Int?
        var isCharging: Bool?
        var isFinishingCharge: Bool?
        var isPresent: Bool?
        var timeToFullMinutes: Int?
        var timeToEmptyMinutes: Int?
        var batteryHealth: String?
        var healthCondition: String?
        var powerSourceState: String?
        var designCycleCount: Int?
        var transportType: String?
    }

    struct AdapterInfo: Sendable {
        var name: String?
        var manufacturer: String?
        var watts: Int?
        var negotiatedVoltageMV: Int?
        var negotiatedCurrentMA: Int?
        var isWireless: Bool?
        var pdoMenu: [PDOEntry] = []
    }

    // MARK: - 电池描述

    static func batteryInfo() -> Info? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            var info = Info()
            info.currentCapacity = RegistrySampler.int(desc[kIOPSCurrentCapacityKey])
            info.maxCapacity = RegistrySampler.int(desc[kIOPSMaxCapacityKey])
            info.isCharging = RegistrySampler.bool(desc[kIOPSIsChargingKey])
            info.isFinishingCharge = RegistrySampler.bool(desc[kIOPSIsFinishingChargeKey])
            info.isPresent = RegistrySampler.bool(desc[kIOPSIsPresentKey])
            info.designCycleCount = RegistrySampler.int(desc["DesignCycleCount"])
            info.transportType = desc[kIOPSTransportTypeKey] as? String
            info.batteryHealth = desc[kIOPSBatteryHealthKey] as? String
            info.healthCondition = desc[kIOPSBatteryHealthConditionKey] as? String
            info.powerSourceState = desc[kIOPSPowerSourceStateKey] as? String
            if let t = RegistrySampler.int(desc[kIOPSTimeToFullChargeKey]), t > 0, t < 65535 {
                info.timeToFullMinutes = t
            }
            if let t = RegistrySampler.int(desc[kIOPSTimeToEmptyKey]), t > 0, t < 65535 {
                info.timeToEmptyMinutes = t
            }
            return info
        }
        return nil
    }

    // MARK: - 适配器详情

    static func adapterInfo() -> AdapterInfo? {
        guard let raw = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        else { return nil }

        var info = AdapterInfo()
        info.name = raw[kIOPSPowerAdapterNameKey] as? String
        info.manufacturer = raw["Manufacturer"] as? String
        info.watts = RegistrySampler.int(raw[kIOPSPowerAdapterWattsKey])
        info.negotiatedVoltageMV = RegistrySampler.int(raw["AdapterVoltage"])
        info.negotiatedCurrentMA = RegistrySampler.int(raw[kIOPSPowerAdapterCurrentKey])
        info.isWireless = RegistrySampler.bool(raw["IsWireless"])
        info.pdoMenu = RegistrySampler.pdoMenu(raw["UsbHvcMenu"])
        return info
    }

    /// 距离充满 / 放完的秒数。-1 表示未知，-2 表示正在充电（无限）
    static func timeRemainingEstimate() -> TimeInterval {
        IOPSGetTimeRemainingEstimate()
    }
}

private let kIOPSPowerAdapterNameKey = "Name"
