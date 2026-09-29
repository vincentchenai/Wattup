import SwiftUI
import AppKit

// MARK: - 提示内容模型

/// 提示的种类。数值统一取「展示那一刻」的最新快照 ——
/// 插上电源的瞬间功率读数还没稳定，早一拍取值只会得到一个 0.0 W。
enum ToastKind: String, Equatable, Sendable {
    case pluggedIn
    case unplugged
    /// 电量跌破设定阈值
    case lowBattery
    /// 插着电但适配器顶不住，电池在倒灌
    case netDischarge
    /// 电池温度超过设定阈值
    case highTemperature
}

/// 一次提示的内容。快照取「展示那一刻」的实时值，所以这里不做相等比较 ——
/// 每次展示都应该按最新读数重新渲染。
struct ToastSpec {
    let kind: ToastKind
    let snapshot: BatterySnapshot
}

// MARK: - 外观档位（由设置面板控制）

/// 尺寸档位对应的具体数值。三档的观感差异全部集中在这里，改数值不用碰视图代码。
struct ToastMetrics {
    let iconBox: CGFloat
    let iconFont: CGFloat
    let titleFont: CGFloat
    let subtitleFont: CGFloat
    let padH: CGFloat
    let padV: CGFloat
    let gap: CGFloat
    let radius: CGFloat
    let minWidth: CGFloat
    let strokeWidth: CGFloat
    /// 光晕至少要有这么大的绘制余量，否则会被面板边界裁成一条直线
    let glowInset: CGFloat
    /// 胶囊本体的估算高度，给预览舞台估高度用
    var estimatedPillHeight: CGFloat { padV * 2 + iconBox }
}

extension AppSettings.ToastSize {
    var metrics: ToastMetrics {
        switch self {
        case .compact:
            return ToastMetrics(iconBox: 27, iconFont: 13, titleFont: 13, subtitleFont: 10.5,
                                padH: 13, padV: 10, gap: 9, radius: 18, minWidth: 220,
                                strokeWidth: 1.4, glowInset: 20)
        case .regular:
            return ToastMetrics(iconBox: 32, iconFont: 15, titleFont: 14.5, subtitleFont: 11.5,
                                padH: 15, padV: 12, gap: 11, radius: 21, minWidth: 250,
                                strokeWidth: 1.6, glowInset: 24)
        case .roomy:
            return ToastMetrics(iconBox: 38, iconFont: 17, titleFont: 16.5, subtitleFont: 12.5,
                                padH: 18, padV: 15, gap: 13, radius: 25, minWidth: 290,
                                strokeWidth: 1.8, glowInset: 28)
        }
    }
}

extension AppSettings.EdgeGlow {
    /// 由内向外叠的同色柔光层（透明度, 半径）。空数组 = 完全不画。
    var halos: [(opacity: Double, radius: CGFloat)] {
        switch self {
        case .off:     return []
        case .regular: return [(0.30, 9)]
        case .strong:  return [(0.40, 15), (0.18, 26)]
        }
    }

    var maxRadius: CGFloat { halos.map(\.radius).max() ?? 0 }

    /// 屏幕顶边那条光带的高度与峰值透明度，关闭时为 0。
    /// **光带与胶囊外的柔光共用同一个档位**，不拆成两个开关 —— 它们本来就是同一个"光晕"的两个落点。
    var bandHeight: CGFloat {
        switch self {
        case .off:     return 0
        case .regular: return 90
        case .strong:  return 150
        }
    }

    var bandAlpha: Double {
        switch self {
        case .off:     return 0
        case .regular: return 0.22
        case .strong:  return 0.34
        }
    }
}

private extension View {
    /// 按档位叠若干层同色柔光。层数写死成 1 / 2 两种 —— SwiftUI 的修饰器是类型级的，没法在循环里追加。
    @ViewBuilder
    func toastHalos(_ halos: [(opacity: Double, radius: CGFloat)], tint: Color) -> some View {
        switch halos.count {
        case 0:
            self
        case 1:
            self.shadow(color: tint.opacity(halos[0].opacity), radius: halos[0].radius)
        default:
            self.shadow(color: tint.opacity(halos[0].opacity), radius: halos[0].radius)
                .shadow(color: tint.opacity(halos[1].opacity), radius: halos[1].radius)
        }
    }
}

extension ToastSpec {
    /// 按当前读数挑一条「此刻最可能真的弹出来」的提示。
    /// 设置面板的实时预览与「预览通知」按钮共用它 —— 试弹出来的那条就是用户真会遇到的那条。
    static func representative(from s: BatterySnapshot) -> ToastSpec {
        guard s.hasBattery else { return ToastSpec(kind: .pluggedIn, snapshot: s) }
        if s.isNetDischargingWhilePlugged { return ToastSpec(kind: .netDischarge, snapshot: s) }
        if s.isExternalConnected { return ToastSpec(kind: .pluggedIn, snapshot: s) }
        if s.percentage <= 20 { return ToastSpec(kind: .lowBattery, snapshot: s) }
        return ToastSpec(kind: .unplugged, snapshot: s)
    }
}

// MARK: - 胶囊视图（对齐 Juicy 的提示样式）

/// Juicy 的提示样式：**屏幕正上方居中的深色胶囊 + 状态色描边 + 色块图标 + 白粗标题 + 灰副标题**。
///
/// 刻意保持简洁：不放进度条、不放右侧大号数字 ——
/// 顶部居中的胶囊是「扫一眼就走」的组件，信息层级一多就变成需要阅读的面板。
struct StatusToastView: View {
    let spec: ToastSpec
    /// 尺寸档位（设置 → 通用 → 提醒气泡尺寸）
    var size: AppSettings.ToastSize = .regular
    /// 外侧柔光强度（设置 → 通用 → 屏幕边缘光晕）
    var glow: AppSettings.EdgeGlow = .regular
    var onTap: (() -> Void)?

    // MARK: 外观派生

    private var m: ToastMetrics { size.metrics }

    /// 画布要留的绘制余量：既要放得下光晕，也不小于档位自带的下限。
    /// 不留够的话柔光会被面板边界裁成一条直线。
    private var inset: CGFloat { max(m.glowInset, glow.maxRadius + 8) }

    // MARK: 内容派生

    private var s: BatterySnapshot { spec.snapshot }

    private var icon: String {
        switch spec.kind {
        case .pluggedIn:
            if s.isFullyCharged { return "checkmark" }
            return s.isCharging ? "bolt.fill" : "powerplug.fill"
        case .unplugged:
            switch s.percentage {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default:    return "battery.100percent"
            }
        case .lowBattery:      return "exclamationmark"
        case .netDischarge:    return "bolt.slash.fill"
        case .highTemperature: return "thermometer.high"
        }
    }

    private var title: String {
        switch spec.kind {
        case .pluggedIn:       return s.isFullyCharged ? "已充满" : (s.isCharging ? "正在充电" : "已接电源")
        case .unplugged:       return "已断开电源"
        case .lowBattery:      return "电量偏低"
        case .netDischarge:    return "适配器功率不足"
        case .highTemperature: return "电池温度偏高"
        }
    }

    private var subtitle: String {
        switch spec.kind {
        case .pluggedIn:
            if s.isFullyCharged { return "改用适配器供电 · \(s.percentage)%" }
            if s.isCharging {
                let watts = (s.systemInputWatts ?? s.batteryNetWatts).map { " · \(Fmt.watts(abs($0), digits: 1))" } ?? ""
                if let t = s.timeToFullMinutes { return "\(Fmt.duration(t))后充满\(watts)" }
                return "正在充电\(watts.isEmpty ? " · 当前 \(s.percentage)%" : watts)"
            }
            return "未在充电 · 当前 \(s.percentage)%"

        case .unplugged:
            if let t = s.timeToEmptyMinutes { return "剩余 \(s.percentage)% · 预计可用 \(Fmt.duration(t))" }
            return "剩余电量 \(s.percentage)%"

        case .lowBattery:
            if let t = s.timeToEmptyMinutes { return "剩余 \(s.percentage)% · 预计可用 \(Fmt.duration(t))" }
            return "剩余电量 \(s.percentage)%，建议接上电源"

        case .netDischarge:
            let shortage = s.adapterHeadroomWatts.map { Fmt.watts(abs($0), digits: 1) } ?? "—"
            return "电池正在倒灌 · 缺 \(shortage)"

        case .highTemperature:
            return "当前 \(Fmt.temperature(s.batteryTemperatureC)) · 建议改善散热"
        }
    }

    /// 状态色：插电看充电语义色，其余看电量档位；告警类固定用橙。
    ///
    /// 做成静态方法是为了让「屏幕边缘光晕」那条光带能取到**同一个颜色** ——
    /// 胶囊与光带各算一套，迟早会出现绿胶囊配橙光带。
    static func tint(for spec: ToastSpec) -> Color {
        let s = spec.snapshot
        switch spec.kind {
        case .pluggedIn:       return s.heroTint
        case .unplugged:       return s.levelTint
        case .lowBattery:      return s.percentage <= 10 ? JB.red : JB.orange
        case .netDischarge:    return JB.orange
        case .highTemperature: return JB.orange
        }
    }

    private var tint: Color { Self.tint(for: spec) }

    /// 充电时空心图标换成实心并脉冲，是这套胶囊里唯一动效
    private var pulses: Bool { spec.kind == .pluggedIn && s.isCharging }

    // MARK: 体

    var body: some View {
        HStack(spacing: m.gap) {
            RoundedRectangle(cornerRadius: m.radius * 0.43, style: .continuous)
                .fill(tint)
                .frame(width: m.iconBox, height: m.iconBox)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: m.iconFont, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating, isActive: pulses)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: m.titleFont, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: m.subtitleFont))
                    .foregroundStyle(Color(white: 0.62))
                    .lineLimit(1)
            }
            // 文字列优先拿宽度，否则中文说明会被图标块挤折行
            .layoutPriority(1)
        }
        .padding(.horizontal, m.padH)
        .padding(.vertical, m.padV)
        .frame(minWidth: m.minWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .fill(Color(nsColor: NSColor(srgbRed: 0.086, green: 0.094, blue: 0.098, alpha: 0.94)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .strokeBorder(tint.opacity(0.85), lineWidth: m.strokeWidth)
        )
        // 描边外散同色柔光，是 Juicy 那种"贴着屏幕发光"的观感。强度由「屏幕边缘光晕」档位决定。
        .toastHalos(glow.halos, tint: tint)
        .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
        // 命中区只给药丸本体。外层那段 padding 是给光晕留的绘制余量，不该顺手吞掉点击。
        .contentShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .onTapGesture { onTap?() }
        .padding(inset)
    }
}

/// 自检用的对照图：行 = 尺寸，列 = 光晕。九种组合画在一张图上，省得逐个改设置去碰。
struct ToastStripView: View {
    let spec: ToastSpec

    /// 每格给一个等高舞台。光晕越强画布要留的余量越大，不定高就会一列比一列低、对不齐。
    private let stageHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(AppSettings.ToastSize.allCases) { size in
                VStack(alignment: .leading, spacing: 8) {
                    Text("尺寸 · \(size.title)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JB.label)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(AppSettings.EdgeGlow.allCases) { glow in
                            VStack(spacing: 6) {
                                Text("光晕 · \(glow.title)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(JB.faint)
                                    .frame(height: 13)
                                StatusToastView(spec: spec, size: size, glow: glow)
                                    .frame(height: stageHeight)
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(SettingsStyle.previewStage)
    }
}

// MARK: - 屏幕边缘光晕

/// 「屏幕边缘光晕」真正的那一层：贴着屏幕顶边、横跨整屏的一条同色光带，向下渐隐。
///
/// 单独一块面板承载，**不并进胶囊那块**：并进去就得把面板撑到整屏宽，
/// 那整条光带（以及它下面一大片透明区）会变成看不见的点击死区。
struct ScreenEdgeGlowView: View {
    let tint: Color
    let glow: AppSettings.EdgeGlow

    var body: some View {
        ZStack {
            // 底色：整宽铺满（垂直方向的衰减交给下面的遮罩，这里不再叠一层，免得两处打架）
            LinearGradient(
                colors: [tint.opacity(glow.bandAlpha), tint.opacity(glow.bandAlpha * 0.55)],
                startPoint: .top, endPoint: .bottom)

            // 光源压在屏幕顶边中央 —— 也就是弹提示的那一侧，让"光"有个来处
            RadialGradient(
                colors: [tint.opacity(glow.bandAlpha * 1.2), tint.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0, endRadius: 520)
        }
        // 垂直衰减**只能由这一层负责**：径向那层在光带底边仍有约 1/4 的 alpha，
        // 不罩住就会在屏幕中间划出一条硬边（实测底边残留 70/255）。
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white.opacity(0.55), location: 0.45),
                    .init(color: .white.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        )
        .frame(height: glow.bandHeight)
        .allowsHitTesting(false)
    }
}

// MARK: - 承载面板

/// 无边框 `NSPanel` 承载胶囊，**屏幕正上方居中**。
///
/// `.nonactivatingPanel` 保证不抢输入焦点 —— 插拔电源、电量告警都是后台事件，
/// 弹个提示把用户正在打的字顶掉是不能接受的。
@MainActor
final class StatusToastController {

    /// 设置面板里的「预览通知」按钮要复用同一块面板，所以留一个共享实例 ——
    /// 两个控制器各持一块面板，提示就会叠在同一位置打架。
    static let shared = StatusToastController()

    private var panel: NSPanel?
    /// 屏幕顶边那条光带的独立面板（`ignoresMouseEvents`，见 makeGlowPanel）
    private var glowPanel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// - Parameters:
    ///   - seconds: nil = 不自动消失（截图自检 / 手动关闭）
    ///   - size: 不传则取设置里的「提醒气泡尺寸」
    ///   - glow: 不传则取设置里的「屏幕边缘光晕」
    func show(_ spec: ToastSpec,
              seconds: Double? = 5,
              size: AppSettings.ToastSize? = nil,
              glow: AppSettings.EdgeGlow? = nil) {
        dismissTask?.cancel()

        let toastSize = size ?? AppSettings.shared.toastSize
        let glowLevel = glow ?? AppSettings.shared.edgeGlow

        // 光带先铺。两块面板同级，后 order 的在上面 —— 所以胶囊在下面再 order 一次；
        // 不过真正的保障是胶囊面板被抬了一级（见 makePanel），不靠这个先后顺序兜底。
        showEdgeGlow(tint: StatusToastView.tint(for: spec), glow: glowLevel)

        let view = StatusToastView(spec: spec, size: toastSize, glow: glowLevel,
                                   onTap: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        host.appearance = NSApp.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let panelSize = NSSize(width: max(fitted.width, 280), height: max(fitted.height, 80))
        host.frame = NSRect(origin: .zero, size: panelSize)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(panelSize)
        panel.contentView = host
        positionAtTopCenter(panel, size: panelSize)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        if let seconds {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                self?.dismiss()
            }
        }
    }

    /// 屏幕正上方居中。用 `visibleFrame.maxY`（已排除菜单栏）而不是 `frame.maxY`，
    /// 免得胶囊盖住菜单栏图标。
    private func positionAtTopCenter(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        let panels = [panel, glowPanel].compactMap { $0 }
        guard !panels.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            for p in panels { p.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.glowPanel?.orderOut(nil)
            }
        }
    }

    /// 自检用：把内容视图自渲染成 PNG（不依赖屏幕录制权限）
    func renderToPNG(path: String) -> Bool {
        render(panel?.contentView, to: path)
    }

    /// 自检用：把屏幕顶边那条光带自渲染成 PNG。
    /// 光带是带 alpha 的渐变，**用 alpha 剖面就能量出档位差异**，比肉眼比两张截图靠谱。
    func renderEdgeGlowToPNG(path: String) -> Bool {
        render(glowPanel?.contentView, to: path)
    }

    private func render(_ view: NSView?, to path: String) -> Bool {
        guard let view else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 铺「屏幕边缘光晕」那条光带。档位为「关闭」时把已有面板收掉。
    private func showEdgeGlow(tint: Color, glow: AppSettings.EdgeGlow) {
        guard glow != .off, let screen = NSScreen.main else {
            glowPanel?.orderOut(nil)
            return
        }

        let panel = glowPanel ?? makeGlowPanel()
        glowPanel = panel

        let host = NSHostingView(rootView: ScreenEdgeGlowView(tint: tint, glow: glow))
        host.appearance = NSApp.effectiveAppearance
        let size = NSSize(width: screen.frame.width, height: glow.bandHeight)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.contentView = host

        // 贴着「可用区上沿」= 菜单栏下沿。锚到 frame.maxY 的话，最亮的那一截正好被菜单栏盖住，
        // 用户只会看到一条已经衰减过的尾巴。
        panel.setFrameOrigin(NSPoint(x: screen.frame.minX,
                                     y: screen.visibleFrame.maxY - size.height))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// 自检用：位置是否真的"屏幕正上方居中"。自渲染截图只证明内容，证明不了位置。
    func positionReport() -> String {
        guard let panel, let screen = NSScreen.main else { return "面板未创建" }
        let f = panel.frame
        let dx = abs(f.midX - screen.frame.midX)
        let belowMenuBar = f.maxY <= screen.visibleFrame.maxY + 0.5
        let aboveDock = f.minY >= screen.visibleFrame.minY
        return "胶囊 frame = \(f)\n"
            + "屏幕 frame = \(screen.frame) · visibleFrame = \(screen.visibleFrame)\n"
            + String(format: "水平居中偏差 %.1f pt（窗口中点 %.1f vs 屏幕中点 %.1f）",
                     dx, f.midX, screen.frame.midX)
            + "\n判定: \(dx <= 1 ? "✅ 水平居中" : "❌ 未居中")"
            + " / \(belowMenuBar ? "✅ 未盖住菜单栏" : "❌ 盖住菜单栏")"
            + " / \(aboveDock ? "✅ 在程序坞之上" : "❌ 压到程序坞")"
            + "\n" + edgeGlowReport(screen: screen)
    }

    private func edgeGlowReport(screen: NSScreen) -> String {
        guard let p = glowPanel else { return "光带: 未创建（当前档位为「关闭」）" }
        let f = p.frame
        let belowMenuBar = f.maxY <= screen.visibleFrame.maxY + 0.5
        let fullWidth = abs(f.width - screen.frame.width) < 0.5
        return "光带 frame = \(f)\n"
            + "光带属性: level = \(p.level.rawValue) · 忽略鼠标 = \(p.ignoresMouseEvents)"
            + " · 带窗口阴影 = \(p.hasShadow)\n"
            + "判定: \(belowMenuBar ? "✅ 贴着菜单栏下沿" : "❌ 盖住菜单栏")"
            + " / \(fullWidth ? "✅ 横跨整屏" : "❌ 未铺满屏宽")"
            + " / \(p.ignoresMouseEvents ? "✅ 不吃点击" : "❌ 会挡住点击")"
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false       // 阴影交给 SwiftUI，见 StatusToastView 注释
        // ⚠️ `isFloatingPanel = true` 会把 level 改写成 `.floating`(3)，所以它必须写在 level **之前**。
        // 反过来写，这里声明的 `.statusBar + 1` 会被悄悄吃掉 —— 实测就是先把 level 写成 3 才发现。
        panel.isFloatingPanel = true
        // 比光带高一级：两块面板都想"在最上面"，抬一级比依赖 order 先后可靠
        panel.level = .statusBar + 1
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func makeGlowPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 同 makePanel：isFloatingPanel 会覆盖 level，必须先写它
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        // 整条光带只是"光"：绝不能吃点击，否则屏幕顶上会出现一条横跨整屏的死区
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}
