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
var lastUT = -1.0, lastAmp = Double.nan, lastSOC = -1.0
var utChanges: [Double] = [], ampChanges: [Double] = []
let t0 = Date()
let dur = 150.0
while Date().timeIntervalSince(t0) < dur {
    let el = Date().timeIntervalSince(t0)
    if let b = snap() {
        let ut = n(b["UpdateTime"]), amp = n(b["Amperage"]), soc = n(b["CurrentCapacity"])
        if ut != lastUT && lastUT > 0 { utChanges.append(el) }
        if !lastAmp.isNaN && amp != lastAmp { ampChanges.append(el) }
        if lastSOC >= 0 && soc != lastSOC { print(String(format: "[t=%.0fs] SOC -> %.0f%%", el, soc)) }
        lastUT = ut; lastAmp = amp; lastSOC = soc
    }
    Thread.sleep(forTimeInterval: 1.0)
}
func rep(_ name: String, _ a: [Double]) {
    guard !a.isEmpty else { print("\(name): 观测期内无变化"); return }
    var g: [Double] = []
    for i in 1..<a.count { g.append(a[i] - a[i-1]) }
    let s = g.isEmpty ? "—" : g.map { String(format: "%.0f", $0) }.joined(separator: ",")
    print("\(name): 变化 \(a.count) 次  平均间隔 \(g.isEmpty ? 0 : g.reduce(0,+)/Double(g.count))s  各次间隔(s): \(s)")
}
print("=== 观测 \(Int(dur))s 结果 ===")
rep("UpdateTime  ", utChanges)
rep("Amperage    ", ampChanges)
