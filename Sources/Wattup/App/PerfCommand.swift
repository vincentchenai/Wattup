import Foundation
import AppKit

/// `--perf`：把「一个轮询周期到底把 CPU 花在哪」拆开量出来。
///
/// 存在的意义：菜单栏工具的能耗几乎是**固定成本 × 频率**，光看 Activity Monitor
/// 的一个总量没法知道该优化哪一项。这里把每个阶段按真实代码路径单独计时，
/// 再乘上它自己的节律，换算成「每小时花多少毫秒 CPU」—— 优化前后各跑一次，
/// 就能说清哪一项省下了多少，而不是笼统地说"优化了"。
///
/// 注意「自己计时自己」的偏差：计时的调用本身有开销，所以测量值略微偏高
/// （< 0.005 ms 量级），对 0.3 ms 以上的阶段可以忽略。
enum PerfCommand {

    /// 该阶段按什么节律跑 —— 能耗问题的另一半是频率，
    /// 同样一项 0.3 ms 的工作，每 5 秒一次和每 60 秒一次，一小时差 12 倍。
    enum Cadence {
        case poll           // 跟着主轮询
        case energyScan     // 跟着能耗扫描
        case onDemand       // 只在用户操作 / 系统事件时跑，不进周期
    }

    struct Row {
        let name: String
        let msPerCall: Double
        let cadence: Cadence
        let note: String
    }

    /// 计时一个同步闭包。先空跑一次热身，避免把首次的惰性初始化（类加载、缓存建立）算进平均。
    static func time(_ iterations: Int, warmup: Int = 1, _ body: () -> Void) -> Double {
        for _ in 0..<max(0, warmup) { body() }
        let iters = max(1, iterations)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iters { body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0 / Double(iters)
    }

    /// 同上，给需要 `await` 的阶段用（`ProcessEnergySampler` 是 actor）。
    static func timeAsync(_ iterations: Int, warmup: Int = 1, _ body: () async -> Void) async -> Double {
        for _ in 0..<max(0, warmup) { await body() }
        let iters = max(1, iterations)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iters { await body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0 / Double(iters)
    }

    /// 让 NSImage 真正光栅化 —— 只建对象不画的话，绘制块是惰性的，量出来的几乎全是噪声。
    private static func rasterize(_ image: NSImage) {        let w = max(1, Int(image.size.width.rounded(.up)))
        let h = max(1, Int(image.size.height.rounded(.up)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: w, pixelsHigh: h,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// - Parameters:
    ///   - iterations: 每个阶段的迭代次数
    ///   - refreshStatusItem: 状态项整轮刷新（AppDelegate 的真实实现，含 AppKit 侧）
    ///   - rasterizeIcon: 是否强制光栅化图标（默认是；量纯绘制成本时可以关掉看差异）
    @MainActor
    static func rows(iterations: Int,
                     refreshStatusItem: () -> Void,
                     snapshot: BatterySnapshot,
                     settings: AppSettings,
                     rasterizeIcon: Bool = true) async -> [Row] {

        let style = settings.effectiveStyle
        let height = settings.iconSize.pillHeight
        let isDark = MenuBarTint.isDark(settings)
        let tint = MenuBarTint.color(for: snapshot, isDark: isDark, settings: settings)

        // 能耗扫描是 actor 隔离的，单独先量。
        // **必须复用同一个采样器**：scan() 首轮只建基线（不做身份解析），
        // 每轮新建实例的话量到的永远是最便宜的那条路径，会系统性低估稳态成本。
        let energySampler = ProcessEnergySampler()
        let energyMS = await timeAsync(iterations) {
            _ = await energySampler.scan()
        }

        return [
            Row(name: "IORegistry 全量读取",
                msPerCall: time(iterations) { _ = RegistrySampler.sample() },
                cadence: .poll,
                note: "AppleSmartBattery 主数据源"),

            Row(name: "公开 API 电池描述",
                msPerCall: time(iterations) { _ = PowerSourceSampler.batteryInfo() },
                cadence: .poll,
                note: "IOPS，补 BatteryHealth 等"),

            Row(name: "公开 API 适配器详情",
                msPerCall: time(iterations) { _ = PowerSourceSampler.adapterInfo() },
                cadence: .poll,
                note: "IOPS，补 PD 档位"),

            Row(name: "菜单栏图标绘制",
                msPerCall: time(iterations) {
                    let img = MenuBarIcon.render(for: snapshot, style: style, tint: tint, height: height)
                    if rasterizeIcon { rasterize(img) }
                },
                cadence: .poll,
                note: rasterizeIcon ? "自绘药丸 + 白字，含光栅化" : "自绘药丸 + 白字，不含光栅化"),

            Row(name: "状态项整轮刷新",
                msPerCall: time(max(3, iterations / 4), warmup: 0) { refreshStatusItem() },
                cadence: .poll,
                note: "长度 + 图标 + 标题 + toolTip"),

            Row(name: "全进程能耗扫描",
                msPerCall: energyMS,
                cadence: .energyScan,
                note: "sysctl 枚举 + 全进程 rusage + 有增量进程的身份解析"),

            Row(name: "低电量模式读取",
                msPerCall: time(5) { _ = LowPowerMode.isEnabled() },
                cadence: .onDemand,
                note: "进程内公开 API；另有 pmset 子进程路径仅自检用"),

            Row(name: "  └ 对照：pmset 子进程",
                msPerCall: time(3) { _ = LowPowerMode.isEnabledViaPmset() },
                cadence: .onDemand,
                note: "旧实现，已移出轮询；保留用于自检交叉验证"),
        ]
    }

    static func stageTable(rows: [Row]) -> String {
        var out = "每阶段成本（单次调用）：\n"
        out += String(format: "  %-20@ %10@  %@\n",
                      "阶段" as NSString, "ms/次" as NSString, "说明" as NSString)
        for r in rows {
            out += String(format: "  %-20@ %10.3f  %@\n",
                          r.name as NSString, r.msPerCall, r.note as NSString)
        }
        return out
    }

    /// 把每阶段成本按各自节律折算成「每小时 CPU 毫秒」。
    /// 节律由 `PowerModel.cadence` 提供 —— 不在这里另写一套数字，
    /// 否则报告会与真实轮询行为脱节，正是最该避免的那种"看起来很准的自检"。
    static func budget(rows: [Row],
                       cadence: PowerModel.RefreshCadence,
                       label: String) -> String {

        var byCadence: [Cadence: Double] = [:]
        for r in rows {
            byCadence[r.cadence, default: 0] += r.msPerCall
        }

        let pollPerTick = byCadence[.poll] ?? 0
        let hourlyPoll = pollPerTick * (3600 / cadence.pollSeconds)
        let hourlyEnergy = (byCadence[.energyScan] ?? 0) * (3600 / cadence.energyScanSeconds)
        let hourlyTotal = hourlyPoll + hourlyEnergy

        var out = "\n【\(label)】\n"
        out += String(format: "  轮询        %.2f s/次 → %6.1f 次/时\n",
                      cadence.pollSeconds, 3600 / cadence.pollSeconds)
        out += String(format: "  能耗扫描    %.1f s/次 → %6.1f 次/时\n",
                      cadence.energyScanSeconds, 3600 / cadence.energyScanSeconds)
        out += "  低电量回读  事件驱动 →     0.0 次/时（系统通知才读）\n"
        out += String(format: "  ── 每轮询周期固定 %7.3f ms × %5.1f 次/时 = %8.1f ms/时\n",
                      pollPerTick, 3600 / cadence.pollSeconds, hourlyPoll)
        out += String(format: "  ── 能耗扫描       %7.3f ms × %5.1f 次/时 = %8.1f ms/时\n",
                      byCadence[.energyScan] ?? 0, 3600 / cadence.energyScanSeconds, hourlyEnergy)
        out += String(format: "  合计 %8.1f ms/时  (%.3f ms/分)\n", hourlyTotal, hourlyTotal / 60)
        return out
    }

    static let closingNote =
        "\n注：只量本进程的同步 CPU 时间；唤醒次数与被唤醒后的窗口服务器合成开销不计入。\n"
}
