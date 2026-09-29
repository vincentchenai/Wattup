import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostedView: NSHostingController<PopoverView>?
    /// 不带滚动的内容视图，专门用来量「自然高度」
    private var measureHost: NSHostingController<PopoverContent>?
    private var previewWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let toast = StatusToastController.shared
    private let settingsWindow = SettingsWindowController.shared
    private var pendingToast: Task<Void, Never>?
    private var watchPowerEvents = false

    private let model = PowerModel.shared
    private let settings = AppSettings.shared

    private func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--dump`：把解析结果打到标准输出后退出，用于核对字段映射
        if CommandLine.arguments.contains("--dump") {
            DumpCommand.run()
            return
        }

        model.onUpdate = { [weak self] in
            self?.refreshStatusItem()
        }
        // 告诉模型「现在有没有界面在展示数据」—— 它据此决定要不要写只服务于展示的指标。
        // 这里集中判断所有会展示数据的窗口，模型侧不感知任何一个窗口类。
        model.isAnySurfaceVisible = { [weak self] in
            guard let self else { return false }
            if self.popover.isShown { return true }
            if self.previewWindow?.isVisible == true { return true }
            if self.settingsWindow.window?.isVisible == true { return true }
            return false
        }
        model.onToast = { [weak self] spec in
            self?.handleToast(spec)
        }
        // 设置面板里改了外观项，菜单栏图标要立刻跟着变。
        // 用 objectWillChange + 下一轮 runloop 读取 —— didSet 先写 UserDefaults，
        // 同一轮里读到的还是旧值。
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)
        // 折叠/展开分区后内容高度变了，重新量一次并调整弹窗
        model.$contentRevision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.syncPopoverSize()
            }
            .store(in: &cancellables)

        // --menubar=batteryIndicator|minimal|mark：临时覆盖形态，不写 UserDefaults
        // （兼容旧值 wattage|percentage|iconOnly）
        for arg in CommandLine.arguments where arg.hasPrefix("--menubar=") {
            let raw = String(arg.dropFirst("--menubar=".count))
            let legacy: [String: AppSettings.MenuBarStyle] = [
                "wattage": .batteryIndicator,
                "percentage": .minimal,
                "iconOnly": .mark,
            ]
            if let style = AppSettings.MenuBarStyle(rawValue: raw) ?? legacy[raw] {
                settings.transientStyle = style
            } else {
                FileHandle.standardError.write(
                    "未知的 --menubar 取值: \(raw)（可选 batteryIndicator/minimal/mark）\n"
                        .data(using: .utf8)!)
            }
        }

        // --appearance=dark|light：强制外观，用于双外观截图核对
        for arg in CommandLine.arguments where arg.hasPrefix("--appearance=") {
            let raw = String(arg.dropFirst("--appearance=".count))
            switch raw {
            case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default:
                FileHandle.standardError.write("未知的 --appearance 取值: \(raw)\n".data(using: .utf8)!)
            }
        }

        // --sections=all|none|flow,health,…：预设分区展开状态，用于截图核对
        applySectionPresetIfNeeded()

        // --icon-strip=<path>：把「该有闪电 / 不该有闪电」的几种状态画成一张对照图
        if let path = Self.snapshotPath(named: "--icon-strip=") {
            writeIconStrip(to: path)
            return
        }

        // --watch-power-events [--watch-seconds=N]：把插拔事件打到 stderr，用于真机验证
        if CommandLine.arguments.contains("--watch-power-events") {
            watchPowerEvents = true
        }

        model.start()

        setUpStatusItem()
        refreshStatusItem()

        // --lpm：只自检低电量模式的读写能力后退出
        if CommandLine.arguments.contains("--lpm") {
            runLowPowerModeCheck()
            return
        }

        // --selfcheck-power-event：用合成快照验证插拔判定（不发真提示）
        if CommandLine.arguments.contains("--selfcheck-power-event") {
            log("=== 插拔事件判定自检 ===")
            for line in model.selfCheckPowerEvents() { log(line) }
            NSApp.terminate(nil)
            return
        }

        // --perf [--perf-iters=N]：把采样各阶段开销拆开量出来（能耗回归用）
        // 必须放在 setUpStatusItem() 之后 —— 「状态项整轮刷新」这一项量的是真实 AppKit 路径。
        if CommandLine.arguments.contains("--perf") {
            let iters = Self.intArg("--perf-iters=") ?? 40
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { NSApp.terminate(nil); return }
                Task { @MainActor in
                    let s = self.model.snapshot
                    let rows = await PerfCommand.rows(
                        iterations: iters,
                        refreshStatusItem: { [weak self] in self?.refreshStatusItem() },
                        snapshot: s,
                        settings: self.settings)

                    var out = "=== 采样开销分解 ===\n"
                    out += "每阶段迭代 \(iters) 次取平均；低电量读取只跑 5 次（每次起一个子进程）。\n"
                    out += "快照：\(s.percentage)% · 充电=\(s.isCharging) · 外接=\(s.isExternalConnected) · 有电池=\(s.hasBattery) · 形态=\(self.settings.effectiveStyle.rawValue)\n\n"
                    out += PerfCommand.stageTable(rows: rows)
                    out += PerfCommand.budget(rows: rows,
                                              cadence: PowerModel.cadence(popoverOpen: false),
                                              label: "弹窗关闭（常态）")
                    out += PerfCommand.budget(rows: rows,
                                              cadence: PowerModel.cadence(popoverOpen: true),
                                              label: "弹窗打开")
                    out += PerfCommand.closingNote
                    self.log(out)
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // --toast=plug|unplug|low|discharge|temp [--toast-shot=<path>]：强制弹一次提示核版式
        if let raw = Self.stringArg("--toast=") {
            let kind: ToastKind = switch raw {
            case "unplug":    .unplugged
            case "low":       .lowBattery
            case "discharge": .netDischarge
            case "temp":      .highTemperature
            default:          .pluggedIn
            }
            let shot = Self.snapshotPath(named: "--toast-shot=")
            let glowShot = Self.snapshotPath(named: "--glow-shot=")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
                // 告警类的读数不能靠真机正好处在告警状态，这里补上典型值
                var s = self.model.snapshot
                switch kind {
                case .lowBattery:
                    s.hasBattery = true; s.percentage = 18
                    s.isCharging = false; s.isExternalConnected = false
                    // 合成值要自己自洽：18% 配一个别的读数会渲出"18% 但还能用 5 小时"这种矛盾截图
                    s.timeToEmptyMinutes = 95
                case .highTemperature:
                    s.hasBattery = true; s.batteryTemperatureC = 48.5
                case .netDischarge:
                    s.hasBattery = true; s.isExternalConnected = true
                    s.batteryPowerMW = -4200
                default:
                    break
                }
                self.toast.show(ToastSpec(kind: kind, snapshot: s), seconds: nil)
                // 自渲染只证明内容，位置要说清楚 —— 一行文本裁定"是否真的屏幕正上方居中"
                self.log(self.toast.positionReport())
                guard shot != nil || glowShot != nil else {
                    // 不给截图路径时就在屏幕上真弹 6 秒，让人肉眼看位置，然后退出
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { NSApp.terminate(nil) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { NSApp.terminate(nil); return }
                    if let shot {
                        let ok = self.toast.renderToPNG(path: shot)
                        FileHandle.standardError.write(
                            "toast snapshot \(ok ? "written" : "failed"): \(shot)\n".data(using: .utf8)!)
                    }
                    if let glowShot {
                        let ok = self.toast.renderEdgeGlowToPNG(path: glowShot)
                        FileHandle.standardError.write(
                            "glow snapshot \(ok ? "written" : "failed"): \(glowShot)\n".data(using: .utf8)!)
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // --toast-strip=<path>：把「尺寸 × 光晕」九种组合一次性画出来。
        // 靠人肉改设置再逐个弹真提示来核对九个组合，效率太低。
        if let path = Self.snapshotPath(named: "--toast-strip=") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.writeToastStrip(to: path)
            }
            return
        }

        // --settings [--settings-shot=<path>] [--settings-pane=<pane>] [--settings-via-button]：
        // 打开应用内设置面板，可指定初始分栏并自渲染截图
        if CommandLine.arguments.contains("--settings") {
            let viaButton = CommandLine.arguments.contains("--settings-via-button")
            let pane = Self.stringArg("--settings-pane=")
                .flatMap(SettingsPane.init(rawValue:)) ?? .menuBar
            if viaButton {
                // 走弹窗底部「设置…」按钮那条无参入口 —— 验证的就是用户真按下去的那段代码，
                // 而不是另开一条自检专用的路径
                SettingsWindowController.shared.show()
            } else {
                settingsWindow.show(settings: settings, model: model, initialPane: pane)
            }

            guard let shot = Self.snapshotPath(named: "--settings-shot=") else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    let w = self?.settingsWindow.window
                    self?.log("设置面板已打开（\(viaButton ? "按钮入口" : "自检入口")，分栏 \(pane.rawValue)）"
                              + " · window=\(w == nil ? "nil ← 未创建" : "已创建 \(w!.frame.size)")")
                    NSApp.terminate(nil)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let w = self.settingsWindow.window else { NSApp.terminate(nil); return }
                // 非 key 窗口里 AppKit 会把开关画成「未激活」的灰色轨道。
                // 这里尽力把窗口抬到最前并夺 key；如果进程始终拿不到 active
                // （从后台 shell 启动时很常见），截图里的开关只会「轨道偏灰」——
                // 滑块位置仍然忠实反映绑定值，开关的取值另见 --verify-popover-fit。
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.capture(w, to: shot)
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // --verify-popover-fit：把「内容自然高度 / 可用高度 / 最终尺寸」打出来
        if CommandLine.arguments.contains("--verify-popover-fit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.verifyPopoverFit()
                NSApp.terminate(nil)
            }
            return
        }

        if watchPowerEvents {
            let seconds = Self.intArg("--watch-seconds=") ?? 90
            // 等首次采样落地再打印当前状态：不然读到的是 empty 快照，会显示成 0% / 未外接
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                let s = self.model.snapshot
                self.log("监听电源事件 \(seconds) 秒。当前：外接=\(s.isExternalConnected) 充电中=\(s.isCharging) 电量=\(s.percentage)%")
                self.log("现在拔掉再插上电源线，事件会实时打在这里。")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) { NSApp.terminate(nil) }
            return
        }

        // 系统切换浅色/深色时，菜单栏底色变了，图标要换用对应档位的绿
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusItem() }
        }

        if CommandLine.arguments.contains("--selfcheck-statusitem-verdict") {
            // 纯判定逻辑自检，不依赖屏幕是否点亮，可随时跑
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.selfCheckStatusItemVerdict()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--verify-statusitem") {
            // 等一次采样落地后自查状态项是否真的挂在菜单栏上
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.verifyStatusItem()
            }
            // 留一段存活时间，方便外部按窗口 ID 单独截图取证
            DispatchQueue.main.asyncAfter(deadline: .now() + 16.0) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--verify-popover") {
            // 走真实的状态项按钮 action，验证「点击 → 弹窗」链路
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
                var out = "=== 弹窗链路自检 ===\n"
                out += "点击前 popover.isShown: \(self.popover.isShown)\n"
                // 真实点击状态项会让本应用成为前台应用，合成 performClick 不会。
                // 不补这一步，弹窗会被当前前台应用的窗口盖住，截不到也看不出层级对不对。
                NSApp.activate(ignoringOtherApps: true)
                self.statusItem?.button?.performClick(nil)
                out += "performClick 后 popover.isShown: \(self.popover.isShown)\n"
                if let w = self.popover.contentViewController?.view.window {
                    out += "popover 窗口 frame: \(w.frame)\n"
                    out += "popover 窗口 isVisible: \(w.isVisible)\n"
                } else {
                    out += "popover 窗口: nil\n"
                }
                out += "弹窗内容尺寸: \(self.popover.contentSize)\n"
                FileHandle.standardError.write(out.data(using: .utf8)!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.0) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--ui-preview") {
            // --warmup=N：先让采样跑 N 秒把历史曲线攒出来，再开窗口截图。
            // 曲线用的是真实采样，不造假数据。
            let warmup = Self.intArg("--warmup=") ?? 0
            if warmup > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(warmup)) { [weak self] in
                    self?.showPreviewWindow()
                }
            } else {
                showPreviewWindow()
            }
        }
    }

    private static func intArg(_ prefix: String) -> Int? {
        for arg in CommandLine.arguments where arg.hasPrefix(prefix) {
            return Int(arg.dropFirst(prefix.count))
        }
        return nil
    }

    private static func stringArg(_ prefix: String) -> String? {
        for arg in CommandLine.arguments where arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    private static func snapshotPath(named prefix: String) -> String? {
        for arg in CommandLine.arguments where arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    // MARK: - 分区展开预设（--sections=）

    /// `--sections=all` 全展开、`none` 全折叠、`flow,energy` 只展开列出的分区。
    /// 直接写 UserDefaults —— CollapsibleCard 建视图时读的就是这个键。
    private func applySectionPresetIfNeeded() {
        guard let raw = Self.stringArg("--sections=") else { return }
        let ids = ["flow", "health", "adapter", "energy"]
        let wanted: Set<String>?
        switch raw {
        case "all":   wanted = Set(ids)
        case "none":  wanted = []
        case "reset":
            for id in ids { UserDefaults.standard.removeObject(forKey: "section.\(id).expanded") }
            return
        default:      wanted = Set(raw.split(separator: ",").map(String.init))
        }
        for id in ids {
            UserDefaults.standard.set(wanted?.contains(id) ?? true, forKey: "section.\(id).expanded")
        }
    }

    // MARK: - 低电量模式自检（--lpm）

    private func runLowPowerModeCheck() {
        var out = "=== 低电量模式自检 ===\n"
        // 这是「轮询循环改用进程内公开 API」这个前提的可验证证据：
        // 两种读法必须一致。用户可以手动切一次低电量模式再跑一遍确认。
        for line in LowPowerMode.compareReadings() { out += line + "\n" }
        out += "\n"

        let before = LowPowerMode.isEnabled()

        // 只试「切到相反值」，试完立刻切回来，不改动用户的实际设置
        let target = !before
        let ok = LowPowerMode.setEnabled(target)
        out += "尝试写入 \(target ? 1 : 0): \(ok ? "成功" : "失败（预期：非 root 会被拒）")\n"
        out += "写后回读: \(LowPowerMode.isEnabled() ? 1 : 0)（应与写前一致）\n"
        if ok { LowPowerMode.setEnabled(before) }   // 恢复
        out += "设置面板 URL: \(SettingsLink.battery)\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
        NSApp.terminate(nil)
    }

    // MARK: - 弹窗适配自检（--verify-popover-fit）

    private func verifyPopoverFit() {
        var out = "=== 弹窗高度自检 ===\n"
        let natural = naturalContentHeight()
        let allowed = maxPopoverHeight()
        out += String(format: "内容自然高度: %.1f pt\n", natural)
        out += String(format: "程序坞之上可用高度: %.1f pt\n", allowed)
        out += String(format: "最终内容高度: %.1f pt（%@）\n",
                      min(natural, allowed), natural > allowed ? "触发滚动" : "完整显示")
        if let button = statusItem?.button, let screen = button.window?.screen ?? NSScreen.main {
            out += "屏幕 frame: \(screen.frame)\n"
            out += "屏幕 visibleFrame: \(screen.visibleFrame) ← 已排除菜单栏与程序坞\n"
            out += "状态项窗口 frame: \(button.window?.frame ?? .zero)\n"
            out += String(format: "弹窗外框高度: %.0f pt（实测值）\n", Self.popoverChromeHeight)
            let content = min(natural, allowed)
            let windowBottom = (button.window?.frame.minY ?? 0) - content - Self.popoverChromeHeight
            out += String(format: "预计弹窗窗口下沿 y ≈ %.1f（程序坞顶 %.1f，需更大）→ %@\n",
                          windowBottom, screen.visibleFrame.minY,
                          windowBottom > screen.visibleFrame.minY ? "停在程序坞上方 ✅" : "压到程序坞 ❌")
        }
        let ids = ["flow", "health", "adapter", "energy"]
        let states = ids.map { id -> String in
            let v = UserDefaults.standard.object(forKey: "section.\(id).expanded") as? Bool
            return "\(id)=\(v.map { $0 ? "展开" : "折叠" } ?? "默认")"
        }
        out += "分区状态: \(states.joined(separator: "  "))\n"
        out += "菜单栏形态: \(settings.effectiveStyle.rawValue) · 附加读数 \(settings.trailing.rawValue)"
        out += " · 大小 \(settings.iconSize.rawValue) · 状态颜色 \(settings.statusColors ? "开" : "关")\n"
        out += "插拔电源提示开关: \(settings.toastEnabled)\n"
        out += "提醒外观: 尺寸 \(settings.toastSize.rawValue) · 光晕 \(settings.edgeGlow.rawValue)\n"
        out += "低电量模式: \(model.lowPowerMode ? "开" : "关")\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }

    // MARK: - 图标状态对照图（--icon-strip）

    /// 把「该有闪电 / 不该有闪电」的几种状态一次性画出来。
    /// 闪电只在 `isCharging` 时出现这件事，靠等真机状态变化去碰运气太低效。
    private func writeIconStrip(to path: String) {
        let isDark = MenuBarTint.isDark(settings)
        let style = settings.effectiveStyle
        // 用法：--icon-strip 配合 --menubar= 与 --appearance= 生成对应形态的对照图
        let styleNote = "形态 \(style.rawValue) · 附加读数 \(settings.trailing.rawValue)"
            + " · 大小 \(settings.iconSize.rawValue)"

        func snap(_ pct: Int, charging: Bool = false, full: Bool = false, plugged: Bool = false) -> BatterySnapshot {
            var s = BatterySnapshot()
            s.hasBattery = true
            s.percentage = pct
            s.isCharging = charging
            s.isFullyCharged = full
            s.isExternalConnected = plugged
            return s
        }

        let rows: [(String, BatterySnapshot)] = [
            ("充电中 67% —— 应有闪电",            snap(67, charging: true, plugged: true)),
            ("已充满 100%（插着电）—— 不应有闪电", snap(100, full: true, plugged: true)),
            ("已充满 100%（拔掉电）—— 不应有闪电", snap(100, full: true)),
            ("电池供电 68% —— 不应有闪电",        snap(68)),
            ("低电量 12% —— 不应有闪电",          snap(12)),
        ]

        let image = MenuBarIcon.debugStrip(isDark: isDark, style: style,
                                           height: settings.iconSize.pillHeight * 2,
                                           rows: rows)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            log("icon strip 渲染失败")
            NSApp.terminate(nil)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        log("icon strip written: \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh), isDark=\(isDark), \(styleNote))")
        NSApp.terminate(nil)
    }

    // MARK: - 提醒外观对照图（--toast-strip）

    /// 把「尺寸 × 光晕」九种组合一次性画出来，省得为核对九个组合反复改设置、反复弹真提示。
    private func writeToastStrip(to path: String) {
        // 合成读数照抄 Juicy 面板里的例子：15% / 9 分钟。两个值要互相自洽，
        // 否则会渲出「15% 但还能用 5 小时」这种自相矛盾的对照图。
        var s = BatterySnapshot()
        s.hasBattery = true
        s.percentage = 15
        s.isCharging = false
        s.isExternalConnected = false
        s.timeToEmptyMinutes = 9

        let host = NSHostingView(rootView: ToastStripView(spec: ToastSpec(kind: .lowBattery, snapshot: s)))
        host.appearance = NSApp.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            log("toast strip 渲染失败")
            NSApp.terminate(nil)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("toast strip 编码失败")
            NSApp.terminate(nil)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        let sizes = AppSettings.ToastSize.allCases.map(\.rawValue).joined(separator: "/")
        let glows = AppSettings.EdgeGlow.allCases.map(\.rawValue).joined(separator: "/")
        log("toast strip written: \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh), 尺寸 \(sizes), 光晕 \(glows))")
        NSApp.terminate(nil)
    }

    // MARK: - 提示胶囊

    /// 提示到达。**插拔要晚一拍**：插上电源的瞬间功率读数还没稳定，
    /// 抢那一两秒只会弹出一个 0.0 W 的提示；告警类没有这个问题，立即弹。
    private func handleToast(_ spec: ToastSpec) {
        switch spec.kind {
        case .pluggedIn, .unplugged:
            logPowerEvent(spec)
            schedulePlugToast(spec.kind)
        case .lowBattery, .netDischarge, .highTemperature:
            toast.show(spec, seconds: settings.toastSeconds)
        }
    }

    private func schedulePlugToast(_ kind: ToastKind) {
        pendingToast?.cancel()
        pendingToast = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            // 1.4 秒里状态可能又翻回去了（瞬时插拔 / 接触不良），确认一下再弹
            let now: ToastKind = self.model.snapshot.isExternalConnected ? .pluggedIn : .unplugged
            guard now == kind else { return }
            // 用「此刻」的最新快照 —— 事件发生那一刻的功率还是旧的
            self.toast.show(ToastSpec(kind: kind, snapshot: self.model.snapshot),
                            seconds: self.settings.toastSeconds)
        }
    }

    private func logPowerEvent(_ spec: ToastSpec) {
        guard watchPowerEvents else { return }
        let s = spec.snapshot
        log(String(format: "[%@] 电源%@  电量 %d%%  充电中 %@  适配器输入 %@  电池净功率 %@",
                   Date().formatted(date: .omitted, time: .standard),
                   spec.kind == .pluggedIn ? "接入" : "断开",
                   s.percentage, s.isCharging ? "是" : "否",
                   Fmt.watts(s.systemInputWatts), Fmt.watts(s.batteryNetWatts)))
    }

    // MARK: - 状态项自检（--verify-statusitem）

    private func verifyStatusItem() {
        var out = ""
        func line(_ s: String) { out += s + "\n" }
        /// 自检的结论只能有一个，且必须在函数退出前落到 stderr。
        var verdict: String?
        func finish() {
            line("")
            line("--- 结论 ---")
            line(verdict ?? "自检未产生结论（提前返回）")
            FileHandle.standardError.write(out.data(using: .utf8)!)
        }

        line("=== 状态项自检 ===")
        line("显示形态: \(settings.effectiveStyle.rawValue) · 附加读数 \(settings.trailing.rawValue) · 大小 \(settings.iconSize.rawValue)")
        // 先亮出「菜单栏此刻该不该画」。锁屏 / 显示器休眠 / 屏保期间整条菜单栏都不绘制，
        // occlusionState 必为 false、layer=25 窗口数必为 0 —— 不能当图标缺陷报。
        let menuBarDrawn = SessionState.isMenuBarDrawn
        line("会话状态: \(SessionState.summary)")
        line("菜单栏是否绘制: \(menuBarDrawn ? "是" : "否  ← \(SessionState.suppressedReason ?? "未知原因")")")
        guard let item = statusItem else {
            line("statusItem: nil  ← 未创建")
            verdict = "✗ 状态项根本没创建。这是代码路径问题，与屏幕状态无关。"
            finish(); return
        }
        line("statusItem: 已创建, isVisible=\(item.isVisible), length=\(item.length)")

        guard let button = item.button else {
            line("button: nil  ← 状态项没有按钮")
            verdict = "✗ 状态项没有按钮。这是代码路径问题，与屏幕状态无关。"
            finish(); return
        }
        line("button.frame: \(button.bounds)")
        line("button.title: \"\(button.title)\"")
        line("button.image: \(button.image == nil ? "nil" : "有 (\(button.image!.size))")")
        line("button.hidden: \(button.isHidden), alpha=\(button.alphaValue)")

        var iconActuallyVisible = false
        var positionEvidence: String?
        // 刘海右侧可用区的起点，用于「窗口坐标是否落在可绘制区」的静态判定。
        var rightAreaMinX: Double?
        if #available(macOS 12.0, *), let r = NSScreen.main?.auxiliaryTopRightArea {
            rightAreaMinX = Double(r.minX)
        }
        if let win = button.window {
            let occ = win.occlusionState.contains(.visible)
            iconActuallyVisible = occ
            line("window: \(type(of: win))")
            line("window.windowNumber: \(win.windowNumber)  ← 哨兵值，screencapture -l 用不了")
            line("window.frame(screen): \(win.frame)")
            line("window.isVisible: \(win.isVisible)")
            line("window.alphaValue: \(win.alphaValue)")
            line("window.level: \(win.level.rawValue)")
            line("window.occlusionState.visible: \(occ)\(occ ? "" : "  ← 未被绘制")")
            line("window.screen: \(win.screen?.localizedName ?? "nil")")
            // 锁屏时 occlusionState 拿不到信息，但窗口坐标照样可读 —— 用它静态判断落位参数
            // 是否正确（这条证据不受屏幕是否点亮影响）。
            if let minX = rightAreaMinX {
                let onRight = Double(win.frame.minX) >= minX
                let evidence = String(format: "窗口坐标 x=%.1f %@刘海右侧可用区（%.1f 起）—— 落位参数%@",
                                      win.frame.minX, onRight ? "落在" : "未落在", minX,
                                      onRight ? "正确" : "可疑，图标可能被藏进刘海左侧")
                positionEvidence = evidence
                line("落位静态判定: \(onRight ? "✓" : "✗") \(evidence)")
            }
        } else {
            line("window: nil  ← 状态项没有被布局到窗口，菜单栏上不会出现")
        }

        if let screen = NSScreen.main {
            line("main screen frame: \(screen.frame)")
            line("main screen visibleFrame: \(screen.visibleFrame)")
            if #available(macOS 12.0, *) {
                if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                    line("刘海左侧可用区: \(l)")
                    line("刘海右侧可用区: \(r)")
                } else {
                    line("无刘海（auxiliary 区域为空）")
                }
            }
        }

        line("--- 菜单栏条带上的所有窗口（含隐藏的，layer=25） ---")
        var menuBarWindowCount = 0
        var mineOnRight = false
        let opts = CGWindowListOption(arrayLiteral: .optionAll)
        if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            var rows: [(x: Double, w: Double, owner: String, name: String, mine: Bool)] = []
            for w in list {
                let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                guard layer == 25 else { continue }
                guard let b = w[kCGWindowBounds as String] as? [String: Any],
                      let x = b["X"] as? Double, let width = b["Width"] as? Double,
                      let y = b["Y"] as? Double else { continue }
                guard y >= 900 else { continue }   // 只看菜单栏那条
                rows.append((x, width, owner,
                             w[kCGWindowName as String] as? String ?? "",
                             owner == "Wattup"))
            }
            rows.sort { $0.x < $1.x }
            var occupied = 0.0
            for r in rows {
                let flag = r.mine ? "   ← 本应用" : ""
                line(String(format: "x=%7.1f w=%6.1f  %@%@", r.x, r.w, r.owner, flag))
                if r.mine, r.x >= 825 { mineOnRight = true }
                if r.x >= 825 { occupied += r.w }
            }
            menuBarWindowCount = rows.count
            line(String(format: "刘海右侧(x≥825)已占用宽度合计 ≈ %.0f pt / 可用 645 pt", occupied))
            line("菜单栏 layer=25 窗口总数: \(menuBarWindowCount)\(menuBarWindowCount == 0 && !menuBarDrawn ? "  ← 屏幕未亮，菜单栏整条不在窗口列表里（预期）" : "")")
        }

        // 结论：把「屏幕不亮」和「图标真被藏了」分开下判。
        verdict = StatusItemVerdict.evaluate(.init(menuBarDrawn: menuBarDrawn,
                                                   suppressedReason: SessionState.suppressedReason,
                                                   iconVisible: iconActuallyVisible,
                                                   onRightSide: mineOnRight,
                                                   positionEvidence: positionEvidence))
        finish()
    }

    /// `--selfcheck-statusitem-verdict`：把状态项可见性的三条判定分支各跑一遍。
    /// 锁屏时真机只能覆盖第一条，这个入口把另外两条也钉住，防止判定逻辑悄悄退化。
    func selfCheckStatusItemVerdict() {
        var out = ""
        func line(_ s: String) { out += s + "\n" }

        line("=== 状态项可见性判定 · 分支自检 ===")
        line("当前会话: \(SessionState.summary)")
        line("")

        let cases: [(name: String, input: StatusItemVerdict.Input)] = [
            ("锁屏（菜单栏整体不绘制）· 带静态落位证据",
             .init(menuBarDrawn: false, suppressedReason: "屏幕已锁定",
                   iconVisible: false, onRightSide: false,
                   positionEvidence: "窗口坐标 x=1001.0 落在刘海右侧可用区（825.0 起）—— 落位参数正确")),
            ("屏幕正常 · 图标落在刘海右侧", .init(menuBarDrawn: true, suppressedReason: nil,
                                                iconVisible: true, onRightSide: true)),
            ("屏幕正常 · 图标落在刘海左侧（被藏）", .init(menuBarDrawn: true, suppressedReason: nil,
                                                      iconVisible: false, onRightSide: false)),
        ]

        var failed = 0
        for (idx, c) in cases.enumerated() {
            line("[\(idx + 1)/\(cases.count)] 输入: 菜单栏绘制=\(c.input.menuBarDrawn) "
                + "图标可见=\(c.input.iconVisible)")
            let verdict = StatusItemVerdict.evaluate(c.input)
            for l in verdict.split(separator: "\n") { line("    \(l)") }

            // 断言：三种输入必须给出三种不同的结论前缀，且前缀符合预期。
            let expectMark: String
            switch idx {
            case 0: expectMark = "○"
            case 1: expectMark = "✓"
            default: expectMark = "✗"
            }
            let ok = verdict.hasPrefix(expectMark)
            if !ok { failed += 1 }
            line("    → 期望前缀 \(expectMark)  实际 \(ok ? "一致" : "不一致 ✗")")
            line("")
        }

        // 再用真实会话状态跑一次，与 --verify-statusitem 的结论保持同源。
        let live = StatusItemVerdict.evaluate(.init(
            menuBarDrawn: SessionState.isMenuBarDrawn,
            suppressedReason: SessionState.suppressedReason,
            iconVisible: statusItem?.button?.window?.occlusionState.contains(.visible) ?? false,
            onRightSide: false))
        line("--- 真实会话状态下的结论 ---")
        for l in live.split(separator: "\n") { line("    \(l)") }
        line("")
        line(failed == 0 ? "✓ 三条分支判定全部符合预期" : "✗ 有 \(failed) 条分支判定不符合预期")

        FileHandle.standardError.write(out.data(using: .utf8)!)
        if failed != 0 { exit(1) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 状态栏

    /// macOS 26 会把「新建的」状态项默认追加到状态区**最左端**。当状态区左端已经越过
    /// 刘海时，系统就把该项当成溢出项塞进刘海左侧区域 —— 那里不会被绘制，但
    /// `isVisible` 仍返回 true、窗口也真实存在。表现就是「应用在跑，图标看不到」。
    ///
    /// `NSStatusItem Preferred Position <autosaveName>` 是系统认可的落位偏好：
    /// 只要它存在，系统就会把该项放进刘海右侧的可见区。所以首次启动时播种一个。
    /// 之后用户 ⌘-拖拽图标，系统会覆盖这个值并按用户位置记忆。
    private func seedStatusItemPositionIfNeeded() {
        let key = "NSStatusItem Preferred Position Wattup"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(200.0, forKey: key)
        }
    }

    private func setUpStatusItem() {
        seedStatusItemPositionIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // autosaveName 让系统记住用户 ⌘-拖拽后的位置，跨启动保持
        item.autosaveName = "Wattup"
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let host = NSHostingController(rootView: PopoverView(model: model))
        host.view.layoutSubtreeIfNeeded()
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 336, height: 560)
        hostedView = host

        // 量高度用的是一个不带滚动的内容视图：ScrollView 的 fittingSize 不可信
        measureHost = NSHostingController(rootView: PopoverContent(model: model))

        syncPopoverSize()
    }

    /// 内容自然高度（没有高度限制、没有滚动条时的真实高度）
    private func naturalContentHeight() -> CGFloat {
        guard let host = measureHost else { return 600 }
        host.view.appearance = NSApp.effectiveAppearance
        host.view.layoutSubtreeIfNeeded()
        return host.view.fittingSize.height
    }

    /// NSPopover 自身的外框高度（箭头 + 内容区上下的内衬）。
    ///
    /// 实测：contentSize.height = 855 时，真实窗口高 881 → 外框占 26 pt。
    /// 这个值必须扣掉，否则「按 contentSize 算出来刚好贴住程序坞」的弹窗
    /// 实际窗口会再往下多伸 26 pt，压到程序坞上 —— 第一次就是这么翻车的。
    private static let popoverChromeHeight: CGFloat = 26

    /// 弹窗允许的最大高度：从状态项下沿到程序坞上沿，扣掉外框再两头留白。
    /// 这样弹窗（含外框）永远停在程序坞上方。
    private func maxPopoverHeight() -> CGFloat {
        guard let button = statusItem?.button,
              let screen = button.window?.screen ?? NSScreen.main else { return 640 }
        let visible = screen.visibleFrame
        let statusItemBottom = button.window?.frame.minY ?? (screen.frame.maxY - 30)
        // 8 pt 给弹窗箭头投影，10 pt 给程序坞上沿留白
        let available = statusItemBottom - 8 - visible.minY - 10 - Self.popoverChromeHeight
        return max(360, available)
    }

    /// 量高度 → 夹到可用高度 → 同时更新 SwiftUI 侧与 NSPopover 侧的尺寸
    private func syncPopoverSize() {
        let natural = naturalContentHeight()
        let height = min(natural, maxPopoverHeight())
        model.popoverBodyHeight = height
        popover.contentSize = NSSize(width: 336, height: height)
    }

    /// 状态项的渲染签名。
    ///
    /// 为什么需要它：`refreshStatusItem()` 会新建 `NSImage`、重设 `statusItem.length`、
    /// 重设 `attributedTitle` 与 `toolTip` —— 每一步都要让状态栏窗口重新合成。
    /// 而电量计 **60 秒** 才更新一次，主轮询却是 5 秒一次：无条件重绘意味着
    /// 12 次里有 11 次在重画一模一样的像素。
    ///
    /// 把一个「影响观感的输入集合」做成可比较的值，一样就直接不碰 AppKit。
    /// 签名只用**输入**而不是渲染结果 —— NSColor / NSImage 的相等性判断不可靠。
    private struct StatusItemSignature: Equatable {
        var style: String
        var iconSize: Double
        var isDark: Bool
        var statusColors: Bool
        var hasBattery: Bool
        var percentage: Int
        var isCharging: Bool
        var isExternalConnected: Bool
        var isNetDischarging: Bool
        var trailing: String
        var tooltip: String
    }

    private var lastStatusSignature: StatusItemSignature?

    private func refreshStatusItem(force: Bool = false) {
        guard let button = statusItem?.button else { return }
        let s = model.snapshot
        let style = settings.effectiveStyle
        let isDark = MenuBarTint.isDark(settings)

        let trailing = style.showsTrailing
            ? MenuBarText.trailing(settings: settings, snapshot: s)
            : ""
        // toolTip 里含 statusText 与瓦数，它们变化时菜单栏像素不变但提示要跟着变 ——
        // 所以把最终字符串本身也放进签名，而不是只放几个"看起来相关"的字段。
        let tooltip = model.menuBarText

        let signature = StatusItemSignature(
            style: style.rawValue,
            iconSize: settings.iconSize.pillHeight,
            isDark: isDark,
            statusColors: settings.statusColors,
            hasBattery: s.hasBattery,
            percentage: s.percentage,
            isCharging: s.isCharging,
            isExternalConnected: s.isExternalConnected,
            isNetDischarging: s.isNetDischargingWhilePlugged,
            trailing: trailing,
            tooltip: tooltip)

        if !force, signature == lastStatusSignature { return }
        lastStatusSignature = signature

        // 「仅标志」用系统方块宽度，占地最小 —— macOS 26 会把放不下的状态项藏到刘海后面
        statusItem?.length = style == .mark
            ? NSStatusItem.squareLength
            : NSStatusItem.variableLength

        // 配色档位可以钉死，也跟随系统外观
        let tint = MenuBarTint.color(for: s, isDark: isDark, settings: settings)

        // 未充电时不画闪电：闪电是「正在充电」的语义，
        // 插着电但已经充满、或者插着电但没在充，都不该出现。
        // 形态与大小统一由 MenuBarIcon.render 决定 —— 设置面板里的预览走同一函数。
        let icon = MenuBarIcon.render(for: s, style: style, tint: tint,
                                      height: settings.iconSize.pillHeight)
        // 关键：不能模板化，否则绿色会被系统抹成单色
        icon.isTemplate = false
        button.image = icon
        button.imagePosition = .imageLeading

        // trailing 上面已经算过（签名要用），这里直接复用，避免同一轮算两遍
        if trailing.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.attributedTitle = NSAttributedString(
                string: " " + trailing,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: 11 * (settings.iconSize.pillHeight / 15), weight: .medium),
                    .foregroundColor: tint,
                ])
        }

        button.toolTip = tooltip

        // 彩色图标已经自带状态色，不能再设 contentTintColor（会覆盖掉绿色）
        button.contentTintColor = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        // 内容高度会随「分区折叠状态」变化，每次打开前重新量一次并夹到程序坞之上
        syncPopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        refreshStatusItem()
    }

    // MARK: - 预览窗口（--ui-preview）

    private func showPreviewWindow() {
        // 预览窗口不受程序坞限制，按内容自然高度整幅渲染（截图核对用）
        model.popoverBodyHeight = naturalContentHeight()

        let host = NSHostingView(rootView: PopoverView(model: model))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(size.width, 340), height: max(size.height, 200)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wattup"
        window.contentView = host
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window

        if let path = Self.snapshotPath() {
            let delay = CommandLine.arguments.contains("--snapshot-delay") ? 6.0 : 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.capture(window, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    private static func snapshotPath() -> String? {
        snapshotPath(named: "--snapshot=")
    }

    /// 用视图自渲染而不是系统截屏，避免依赖屏幕录制权限
    private func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(
                "snapshot written: \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
        }
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        model.popoverDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverDidClose()
    }
}
