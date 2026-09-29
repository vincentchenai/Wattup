import Foundation
import IOKit
import IOKit.ps
import Darwin

// ---------- 1) SMC 服务是否可匹配（决定能否读 SMC key / 做充电控制）----------
print("=== SMC 服务可达性 ===")
let smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
print("  IOServiceMatching(\"AppleSMC\") -> \(smc)  \(smc == 0 ? "(未匹配到：该平台无此服务节点)" : "(可匹配)")")
if smc != 0 {
    var connect: io_connect_t = 0
    let kr = IOServiceOpen(smc, mach_task_self_, 0, &connect)
    print("  IOServiceOpen(type=0) kern_return = \(kr)")
    if connect != 0 { IOServiceClose(connect) }
    IOObjectRelease(smc)
}

// ---------- 2) 单次采样成本 ----------
func readBatteryDict() -> [String: Any]? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return nil }
    defer { IOObjectRelease(s) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return d
}

func ms(_ block: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
}

print("\n=== 单次 IORegistry 全量属性读取耗时（100 次）===")
var k = 0
let t1 = ms { for _ in 0..<100 { if readBatteryDict() != nil { k += 1 } } }
print("  成功 \(k)/100  平均 \(String(format: "%.3f", t1 / 100)) ms/次  合计 \(String(format: "%.1f", t1)) ms")

print("\n=== 仅读一次（含匹配服务）耗时 ===")
for i in 1...3 {
    let t = ms { _ = readBatteryDict() }
    print("  第\(i)次: \(String(format: "%.3f", t)) ms")
}

print("\n=== IOPS 适配器详情读取耗时（100 次）===")
let t2 = ms { for _ in 0..<100 { if let r = IOPSCopyExternalPowerAdapterDetails() { _ = r.takeRetainedValue() } } }
print("  平均 \(String(format: "%.3f", t2 / 100)) ms/次")

// ---------- 3) 全进程能耗扫描成本 ----------
print("\n=== 全进程 proc_pid_rusage 扫描耗时（10 次）===")
func scanAll() -> Int {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var len = 0
    guard sysctl(&mib, 4, nil, &len, nil, 0) == 0 else { return 0 }
    let count = len / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 64)
    guard sysctl(&mib, 4, &procs, &len, nil, 0) == 0 else { return 0 }
    let n = len / MemoryLayout<kinfo_proc>.stride
    var ok = 0
    for i in 0..<n {
        let pid = procs[i].kp_proc.p_pid
        if pid <= 0 { continue }
        var ri = rusage_info_v6()
        if proc_pid_rusage(pid, RUSAGE_INFO_V6, withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self) }
        }) == 0 { ok += 1 }
    }
    return ok
}
let t3 = ms { for _ in 0..<10 { _ = scanAll() } }
print("  平均 \(String(format: "%.2f", t3 / 10)) ms/次（约 550 个进程）")

// ---------- 4) 后台自身开销 ----------
var usage = rusage()
_ = getrusage(RUSAGE_SELF, &usage)
print("\n=== 本探针自身开销 ===")
print("  用户态 CPU: \(String(format: "%.1f", Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6)) s")
print("  系统态 CPU: \(String(format: "%.1f", Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6)) s")
