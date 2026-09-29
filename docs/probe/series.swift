import Foundation
import IOKit
func snap() -> [String: Any]? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return nil }
    defer { IOObjectRelease(s) }
    var p: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = p?.takeRetainedValue() as? [String: Any] else { return nil }
    return d
}
func n(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }
print("t      SOC I(mA) V(mV)  ChgI  ChgV | SysIn  SysLoad BatP   | P=I*V  Δ   | UpdateTime")
var lastUT = 0.0, lastAmp = Double.nan
var changes = 0, samples = 0
var utTimes: [Double] = []
for i in 0...29 {
    if let b = snap() {
        let pt = b["PowerTelemetryData"] as? [String: Any] ?? [:]
        let cd = b["ChargerData"] as? [String: Any] ?? [:]
        let amp = n(b["Amperage"]), vol = n(b["Voltage"])
        let ut = n(b["UpdateTime"])
        samples += 1
        if !lastAmp.isNaN && amp != lastAmp { changes += 1 }
        if ut != lastUT { utTimes.append(Double(i) * 1.0) }
        lastAmp = amp; lastUT = ut
        print(String(format: "%4.0fs %4.0f %5.0f %6.0f %5.0f %5.0f | %6.0f %7.0f %6.0f | %6.0f %5.0f | %.0f",
            Double(i), n(b["CurrentCapacity"]), amp, vol,
            n(cd["ChargingCurrent"]), n(cd["ChargingVoltage"]),
            n(pt["SystemPowerIn"]), n(pt["SystemLoad"]), n(pt["BatteryPower"]),
            vol * amp / 1000.0, n(pt["SystemPowerIn"]) - n(pt["SystemLoad"]), ut))
    }
    Thread.sleep(forTimeInterval: 1.0)
}
print("\n采样 \(samples) 次, Amperage 变化次数 = \(changes)")
print("UpdateTime 变化的时刻(s): \(utTimes.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
if utTimes.count > 1 {
    var gaps: [Double] = []
    for i in 1..<utTimes.count { gaps.append(utTimes[i] - utTimes[i-1]) }
    print("刷新间隔(s): \(gaps.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
}
