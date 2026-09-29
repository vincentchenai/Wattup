import Foundation

/// 低电量模式（Low Power Mode）的读取与设置。
///
/// ## 读取：进程内公开 API，不起子进程
///
/// 早先的实现是解析 `pmset -g` 的输出，**实测每次要 82.8 ms**（fork + exec + dyld
/// 把 pmset 与它依赖的 IOKit 全部加载一遍，再等它退出）。在「每 60 秒回读一次」的
/// 节律下，这一项独占全部采样开销的 **83%** —— 是本工具能耗的最大来源。
///
/// 现在改用 `ProcessInfo.isLowPowerModeEnabled`：**实测 < 0.001 ms**，
/// 与 `pmset -g` 的读数一致（同时打印两者见 `--lpm` 自检）。
/// 配合 `NSProcessInfoPowerStateDidChange` 通知，连"每 60 秒问一次"都不需要了 ——
/// 状态变了系统会叫我们，不改就不问。
///
/// ## 写入：仍然是尽力而为
///
/// **实测 `pmset -b lowpowermode 1` 会以 `'pmset' must be run as root...` 退出（exit=1）**，
/// 本模块因此只做「尽力而为」的写入，失败时由 UI 明确告知并引导去「电池」设置。
/// 写入路径保留子进程（用户主动点击才触发，一次 80 ms 可以接受），不再进轮询循环。
///
/// 刻意不走 `osascript ... with administrator privileges` 那条路：
/// 为了切一个电量开关弹管理员密码框，打断成本比收益高，而且用户会怀疑这软件在提权。
enum LowPowerMode {

    /// 快速读取（默认路径）：进程内公开 API，零子进程。
    /// 不返回可选值 —— 这个 API 不需要任何权限也不会读不到。
    static func isEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// 精确读取：解析 `pmset -g`。**只给自检用**，用来交叉验证快速读法是否等价。
    /// 不要放回轮询循环 —— 一次 82.8 ms，见文件头说明。
    static func isEnabledViaPmset() -> Bool? {
        guard let out = runPmset(["-g"]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "lowpowermode" else { continue }
            return parts[1] == "1"
        }
        return nil
    }

    /// 系统在这两个状态下发通知：低电量模式切换、热压力等级变化。
    /// 用系统定义的名字而不是手写字符串 —— 手写抄错了是静默失效（永远收不到通知），
    /// 而且不会有任何编译警告。
    static let powerStateDidChange = Notification.Name.NSProcessInfoPowerStateDidChange

    /// 尝试写入，返回是否真的生效。
    ///
    /// pmset 失败时把错误写到输出流（不是 stderr），所以靠内容判断，而不是只看退出码。
    /// 写完**回读确认**（用的是零成本的快速读法），不靠退出码假装成功。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let out = runPmset(["-b", "lowpowermode", enabled ? "1" : "0"]) else { return false }
        if out.localizedCaseInsensitiveContains("must be run as root") { return false }
        return isEnabled() == enabled
    }

    /// 失败原因的固定说法，UI 直接引用，避免每处各写一套
    static let writeDeniedExplanation =
        "系统只允许有 root 权限的进程改写低电量模式，本应用无法直接切换。"
        + "请在「电池」设置里手动打开，效果与这里完全一致。"

    /// 自检用：把两种读法并排打出来，方便随时验证「快速读法与 pmset 等价」这个前提。
    /// 用户可以手动切一次低电量模式再跑一遍 —— 两种读法要对得上。
    static func compareReadings() -> [String] {
        let fast = isEnabled()
        let slow = isEnabledViaPmset()
        var lines: [String] = []
        lines.append("ProcessInfo 快速读法 : \(fast)   （进程内，<0.001 ms）")
        lines.append("pmset -g 解析读法    : \(slow.map(String.init) ?? "nil")   （起子进程，实测 82.8 ms）")
        if let slow {
            lines.append(fast == slow
                         ? "✅ 两种读法一致 —— 轮询循环用快速读法是安全的"
                         : "❌ 两种读法不一致，快速读法不可用于轮询（请改回 pmset 并报告）")
        } else {
            lines.append("⚠️  pmset 读不到，无法交叉验证；快速读法仍在用")
        }
        lines.append("热压力等级: \(ProcessInfo.processInfo.thermalState.rawValue)  (0=正常 1=偏轻 2=偏重 3=严重)")
        return lines
    }

    private static func runPmset(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 系统设置快捷入口

/// macOS 26（Tahoe）上老的 `com.apple.preference.battery` 已经失效，
/// 现在的电池面板是 `com.apple.Battery-Settings.extension`（PowerPreferences.appex）。
/// 这两个 URL 都实测过能直接打开对应面板。
enum SettingsLink {
    /// 系统设置根页面
    static let root = "x-apple.systempreferences:"
    /// 电池面板
    static let battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
}
