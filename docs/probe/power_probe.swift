// 验证：普通（非 root、非特权）进程能否通过 IOKit 公开 API + IORegistry 拿到功率/电流/电压
import Foundation
import IOKit
import IOKit.ps

func readAppleSmartBattery() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return dict
}

func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

print("=== 1) IORegistry: AppleSmartBattery ===")
if let b = readAppleSmartBattery() {
    print("CurrentCapacity        = \(b["CurrentCapacity"] ?? "-") %")
    print("IsCharging             = \(b["IsCharging"] ?? "-")")
    print("FullyCharged           = \(b["FullyCharged"] ?? "-")")
    print("ExternalConnected      = \(b["ExternalConnected"] ?? "-")")
    print("Voltage (pack, mV)     = \(b["Voltage"] ?? "-")")
    print("Amperage (pack, mA)    = \(b["Amperage"] ?? "-")")
    print("InstantAmperage (mA)   = \(b["InstantAmperage"] ?? "-")")
    print("Temperature (1/100 C)  = \(b["Temperature"] ?? "-")")
    print("CycleCount             = \(b["CycleCount"] ?? "-")")
    print("DesignCapacity (mAh)   = \(b["DesignCapacity"] ?? "-")")
    print("AppleRawMaxCapacity    = \(b["AppleRawMaxCapacity"] ?? "-")")
    print("NominalChargeCapacity  = \(b["NominalChargeCapacity"] ?? "-")")
    print("TimeRemaining (min)    = \(b["TimeRemaining"] ?? "-")")
    if let ad = b["AdapterDetails"] as? [String: Any] {
        print("AdapterDetails.Watts   = \(ad["Watts"] ?? "-")")
        print("AdapterDetails.Current = \(ad["Current"] ?? "-") mA")
        print("AdapterDetails.Voltage(AdapterVoltage) = \(ad["AdapterVoltage"] ?? "-") mV")
        print("AdapterDetails.Name    = \(ad["Name"] ?? "-")")
    }
    if let cd = b["ChargerData"] as? [String: Any] {
        print("ChargerData.ChargingCurrent = \(cd["ChargingCurrent"] ?? "-") mA")
        print("ChargerData.ChargingVoltage = \(cd["ChargingVoltage"] ?? "-") mV")
        print("ChargerData.NotChargingReason = \(cd["NotChargingReason"] ?? "-")")
        print("ChargerData.SlowChargingReason = \(cd["SlowChargingReason"] ?? "-")")
    }
    if let pt = b["PowerTelemetryData"] as? [String: Any] {
        let sysIn = num(pt["SystemPowerIn"]) ?? 0
        let sysLoad = num(pt["SystemLoad"]) ?? 0
        let battP = num(pt["BatteryPower"]) ?? 0
        let sCurIn = num(pt["SystemCurrentIn"]) ?? 0
        let sVoltIn = num(pt["SystemVoltageIn"]) ?? 0
        let effLoss = num(pt["AdapterEfficiencyLoss"]) ?? 0
        print("Telemetry.SystemPowerIn    = \(sysIn) mW  (\(sysIn / 1000.0) W)")
        print("Telemetry.SystemLoad       = \(sysLoad) mW  (\(sysLoad / 1000.0) W)")
        print("Telemetry.BatteryPower     = \(battP) mW  (\(battP / 1000.0) W)")
        print("Telemetry.SystemCurrentIn  = \(sCurIn) mA")
        print("Telemetry.SystemVoltageIn  = \(sVoltIn) mV")
        print("Telemetry.AdapterEffLoss   = \(effLoss) mW")
        print("Telemetry.WallEnergyEstimate = \(pt["WallEnergyEstimate"] ?? "-")")
        print("-> 校验: 电池净功率 = Voltage*Amperage = \((num(b["Voltage"]) ?? 0) * (num(b["Amperage"]) ?? 0) / 1000.0) mW")
    }
    if let bd = b["BatteryData"] as? [String: Any] {
        print("BatteryData.CellVoltage = \(bd["CellVoltage"] ?? "-")")
        print("BatteryData.Qmax        = \(bd["Qmax"] ?? "-")")
        print("BatteryData.WeightedRa  = \(bd["WeightedRa"] ?? "-")")
        print("BatteryData.ChemID      = \(bd["ChemID"] ?? "-")")
    }
} else {
    print("AppleSmartBattery 读取失败（可能是台式机/无电池）")
}

print("\n=== 2) 公开 API: IOPSCopyExternalPowerAdapterDetails ===")
if let raw = IOPSCopyExternalPowerAdapterDetails(), let ad = raw.takeRetainedValue() as? [String: Any] {
    for (k, v) in ad.sorted(by: { $0.key < $1.key }) { print("  \(k) = \(v)") }
} else {
    print("  未连接适配器或返回 nil")
}

print("\n=== 3) 公开 API: IOPSCopyPowerSourcesInfo（系统电池面板同源）===")
if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
   let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
    for src in list {
        if let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] {
            for (k, v) in d.sorted(by: { $0.key < $1.key }) { print("  \(k) = \(v)") }
        }
    }
}

print("\n=== 4) 公开 API: IOPSGetTimeRemainingEstimate ===")
print("  seconds = \(IOPSGetTimeRemainingEstimate())  (kIOPSTimeRemainingUnlimited = \(kIOPSTimeRemainingUnlimited), unknown = \(kIOPSTimeRemainingUnknown))")
