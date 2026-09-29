import Foundation
import Darwin

/// 单个应用的能耗占用（已把 helper 进程归并到所属 App）
struct AppEnergy: Sendable, Identifiable {
    let bundlePath: String
    let displayName: String
    /// 采样窗口内累计的能耗增量（纳焦耳）
    let nanojoules: UInt64
    /// 折算功率（毫瓦）
    let milliWatts: Double
    /// 归并进来的进程数
    let processCount: Int
    /// 占「已计量合计」的比例 0...1
    let share: Double

    var id: String { bundlePath }
}

/// 一次能耗扫描的结果
struct EnergyScanResult: Sendable {
    var apps: [AppEnergy] = []
    var measuredMilliWatts: Double = 0
    var measuredProcessCount = 0
    var totalProcessCount = 0
    /// 因权限被拒（非当前用户）的进程数
    var deniedProcessCount = 0
    var windowSeconds: Double = 0
    var isBaselineReady = false
}

/// 应用能耗采集器。
///
/// 实测（MacBook Air M5 / macOS 26.6.2）：
/// - `proc_pid_rusage(RUSAGE_INFO_V6)` 全量扫描 550 进程耗时 1.09 ms
/// - 权限边界严格等价于用户归属：同 uid 497/497 可读，异 uid 0/201 被拒，零例外
/// - `ri_energy_nj` 为单调累计量，必须两次采样求差分才能得到功率
/// - 进程能耗合计仅占整机 SystemLoad 约 8%，因此只呈现相对占比，不呈现绝对瓦数
actor ProcessEnergySampler {

    private struct ProcessRecord {
        var energyNJ: UInt64
        /// 只在**该进程这一轮真的有能耗增量**时才解析。
        /// 从没增量的进程不必知道它是谁 —— 不知道它就不会进排行。
        var bundlePath: String?
        var displayName: String?
    }

    private var previous: [pid_t: ProcessRecord] = [:]
    private var previousTimestamp: Date?
    private var nameCache: [String: String] = [:]

    /// 重置基线。电源状态变化后应当调用，避免把状态切换当作能耗增量。
    func resetBaseline() {
        previous.removeAll()
        previousTimestamp = nil
    }

    /// 一次扫描的成本大头是**逐个进程解析身份**：`proc_pidpath` 每次要拷最多 1024 字节，
    /// 550 个进程全做一遍就是 0.5 MB 的内存搬运，而绝大多数进程在两次扫描之间
    /// 压根没有能耗增量。所以这里把身份解析推迟到「确认有增量」之后再做 ——
    /// 实测把扫描耗时从 ~5.2 ms 降到 ~1 ms 量级（见 `--perf`）。
    func scan() -> EnergyScanResult {
        let now = Date()
        let procs = Self.listProcesses()

        var current: [pid_t: ProcessRecord] = [:]
        current.reserveCapacity(procs.count)

        var okCount = 0
        var deniedCount = 0
        let myUID = getuid()
        // 首轮扫描只建基线，不做任何身份解析
        let hasBaseline = previousTimestamp != nil && !previous.isEmpty

        for p in procs {
            guard p.pid > 0 else { continue }
            var ri = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ri) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(p.pid, RUSAGE_INFO_V6, rebound)
                }
            }
            guard rc == 0 else {
                if p.uid != myUID { deniedCount += 1 }
                continue
            }
            okCount += 1

            var key: String?
            var name: String?
            if hasBaseline, let old = previous[p.pid], ri.ri_energy_nj > old.energyNJ {
                let path = Self.executablePath(of: p.pid) ?? ""
                let k = Self.bundleKey(for: path)
                key = k
                name = displayName(for: k, fallbackPath: path, pid: p.pid)
            }
            current[p.pid] = ProcessRecord(energyNJ: ri.ri_energy_nj,
                                           bundlePath: key,
                                           displayName: name)
        }

        var result = EnergyScanResult()
        result.measuredProcessCount = okCount
        result.deniedProcessCount = deniedCount
        result.totalProcessCount = procs.count

        defer {
            previous = current
            previousTimestamp = now
        }

        // 首次扫描只建立基线，不算增量
        guard let lastTime = previousTimestamp, !previous.isEmpty else {
            result.isBaselineReady = false
            return result
        }

        let window = now.timeIntervalSince(lastTime)
        guard window > 0.2 else {
            result.isBaselineReady = false
            return result
        }
        result.windowSeconds = window
        result.isBaselineReady = true

        // 按 App 归并增量。只有「解析过身份」的记录才可能进来 —— 也就是真有增量的那些。
        var byBundle: [String: (nj: UInt64, name: String, count: Int)] = [:]
        for (pid, rec) in current {
            guard let key = rec.bundlePath, let name = rec.displayName,
                  let old = previous[pid], rec.energyNJ > old.energyNJ else { continue }
            let delta = rec.energyNJ - old.energyNJ
            guard delta > 0 else { continue }
            var entry = byBundle[key] ?? (0, name, 0)
            entry.nj += delta
            entry.count += 1
            byBundle[key] = entry
        }

        let totalNJ = byBundle.values.reduce(UInt64(0)) { $0 + $1.nj }
        let totalMW = Double(totalNJ) / 1_000_000 / window   // nJ -> mJ -> W -> mW

        result.measuredMilliWatts = totalMW
        result.apps = byBundle
            .map { key, value in
                AppEnergy(bundlePath: key,
                          displayName: value.name,
                          nanojoules: value.nj,
                          milliWatts: Double(value.nj) / 1_000_000 / window,
                          processCount: value.count,
                          share: totalNJ > 0 ? Double(value.nj) / Double(totalNJ) : 0)
            }
            .sorted { $0.nanojoules > $1.nanojoules }

        return result
    }

    // MARK: - 进程枚举

    private struct ProcEntry {
        let pid: pid_t
        let uid: uid_t
    }

    /// 只枚举 pid 与 uid。
    ///
    /// **刻意不在这里解析可执行路径** —— 那是 `proc_pidpath`，每个进程要拷最多 1024 字节。
    /// 枚举阶段还不知道谁有能耗增量，全解析就是 550 次白干（原先的实现正是如此）。
    /// 身份解析交给 `scan()`，只对真有增量的进程做。
    private static func listProcesses() -> [ProcEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        let capacity = length / MemoryLayout<kinfo_proc>.stride + 64
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &buffer, &length, nil, 0) == 0 else { return [] }

        let count = length / MemoryLayout<kinfo_proc>.stride
        var out: [ProcEntry] = []
        out.reserveCapacity(count)

        for i in 0..<count {
            let kp = buffer[i]
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            out.append(ProcEntry(pid: pid, uid: kp.kp_eproc.e_ucred.cr_uid))
        }
        return out
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 把 `.../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper` 归并到 `.../Google Chrome.app`
    private static func bundleKey(for path: String) -> String {
        guard let range = path.range(of: ".app/") else { return path }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    private func displayName(for key: String, fallbackPath: String, pid: pid_t) -> String {
        if let cached = nameCache[key] { return cached }

        var name: String
        if key.hasSuffix(".app") {
            if let bundle = Bundle(path: key) {
                let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
                name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                name = ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            }
        } else if !fallbackPath.isEmpty {
            name = Self.prettify((fallbackPath as NSString).lastPathComponent, pid: pid)
        } else {
            var buf = [CChar](repeating: 0, count: 256)
            let raw = proc_name(pid, &buf, 256) > 0 ? String(cString: buf) : "pid \(pid)"
            name = Self.prettify(raw, pid: pid)
        }

        nameCache[key] = name
        return name
    }

    /// 系统守护进程的可执行名往往是反向域名，直接显示会被截断成
    /// `com.app...IMachine` 这种看不出是什么的样子，这里取最后一段。
    private static func prettify(_ raw: String, pid: pid_t) -> String {
        guard raw.hasPrefix("com.apple.") else { return raw }
        let parts = raw.split(separator: ".")
        if parts.count >= 4, let last = parts.last, last.count >= 3 {
            return String(last)
        }
        return raw
    }
}
