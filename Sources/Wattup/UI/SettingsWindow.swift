import SwiftUI
import AppKit

// MARK: - 分栏定义

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, alerts, menuBar, charging, usage, battery, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "通用"
        case .alerts:   return "提醒"
        case .menuBar:  return "菜单栏"
        case .charging: return "充电"
        case .usage:    return "App 用量"
        case .battery:  return "电池"
        case .about:    return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general:  return "gearshape.fill"
        case .alerts:   return "bell.badge.fill"
        case .menuBar:  return "menubar.rectangle"
        case .charging: return "bolt.fill"
        case .usage:    return "chart.bar.fill"
        case .battery:  return "battery.100percent"
        case .about:    return "info.circle.fill"
        }
    }

    var chip: Color {
        switch self {
        case .general:  return Color(nsColor: .adaptive(light: "#6E6E76", dark: "#9BA3A7"))
        case .alerts:   return JB.orange
        case .menuBar:  return JB.green
        case .charging: return Color(nsColor: .adaptive(light: "#C2710A", dark: "#FFB84D"))
        case .usage:    return Color(nsColor: .adaptive(light: "#0A63C2", dark: "#4DA3FF"))
        case .battery:  return JB.green
        case .about:    return Color(nsColor: .adaptive(light: "#6E6E76", dark: "#9BA3A7"))
        }
    }

    static let groups: [(String?, [SettingsPane])] = [
        (nil, [.general, .alerts, .menuBar, .charging]),
        ("测量", [.usage, .battery]),
        ("Wattup", [.about]),
    ]
}

// MARK: - 设置窗口

@MainActor
final class SettingsWindowController {

    /// 弹窗底部「设置…」直接用这个入口，不经过 AppDelegate
    static let shared = SettingsWindowController()

    /// 自检与截图需要拿到窗口本体
    private(set) var window: NSWindow?

    /// 便捷入口：设置模型与数据源都取各自单例
    func show() {
        show(settings: AppSettings.shared, model: PowerModel.shared)
    }

    func show(settings: AppSettings, model: PowerModel, initialPane: SettingsPane = .menuBar) {
        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView(settings: settings, model: model, initialPane: initialPane))
            let w = NSWindow(contentViewController: host)
            w.title = "Wattup 设置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 560))
            w.minSize = NSSize(width: 660, height: 480)
            w.center()
            window = w
        }
        // LSUIElement 应用不开这一步，窗口会出现在所有前台窗口后面
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 设置主视图

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    @State private var pane: SettingsPane

    init(settings: AppSettings, model: PowerModel, initialPane: SettingsPane = .menuBar) {
        self.settings = settings
        self.model = model
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(JB.cardStroke).frame(width: 0.5)
            detail
        }
        .frame(minWidth: 660, minHeight: 480)
        .background(SettingsStyle.windowFill)
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                if let caption = group.0 {
                    Text(caption)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                }
                ForEach(group.1) { item in
                    Button {
                        withAnimation(.smooth(duration: 0.18)) { pane = item }
                    } label: {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(item.chip)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                )
                            Text(item.title)
                                .font(.system(size: 12.5, weight: pane == item ? .semibold : .regular))
                                .foregroundStyle(JB.value)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(pane == item ? SettingsStyle.sidebarSelection : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9)
                }
            }

            Spacer(minLength: 12)

            // 底部不放促销卡片，只放真实状态 —— 设置面板里出现"快来买"会削弱可信度
            VStack(alignment: .leading, spacing: 2) {
                Text("Wattup \(Self.version)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(JB.label)
                Text("采样 \(String(format: "%.2f", model.lastSampleDurationMS)) ms · 已刷新 \(model.refreshCount) 次")
                    .font(.system(size: 10))
                    .foregroundStyle(JB.faint)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(width: 196)
        .padding(.top, 34)          // 让开透明标题栏
        .background(SettingsStyle.sidebarFill)
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    // MARK: 详情

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(pane.chip)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: pane.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                    Text(pane.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JB.value)
                    Spacer(minLength: 0)
                }

                switch pane {
                case .general:  GeneralPane(settings: settings, model: model)
                case .alerts:   AlertsPane(settings: settings)
                case .menuBar:  MenuBarPane(settings: settings, model: model)
                case .charging: ChargingPane(settings: settings, model: model)
                case .usage:    UsagePane(settings: settings, model: model)
                case .battery:  BatteryPane(model: model)
                case .about:    AboutPane(model: model)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 版式令牌

enum SettingsStyle {
    static var windowFill: Color {
        Color(nsColor: .adaptive(light: "#FFFFFF", dark: "#1B1F21"))
    }
    static var sidebarFill: Color {
        Color(nsColor: .adaptive(light: "#F2F2F5", dark: "#15181A"))
    }
    static var sidebarSelection: Color {
        Color(nsColor: .adaptive(light: "#E2E2E8", dark: "#2C3236"))
    }
    static var cardFill: Color {
        Color(nsColor: .adaptive(light: "#F7F7F9", dark: "#22282B"))
    }
    /// 提醒外观预览的底色。刻意不用纯白 —— 同色柔光在纯白上几乎看不见。
    static var previewStage: Color {
        Color(nsColor: .adaptive(light: "#DCDCE2", dark: "#0F1315"))
    }
}

// MARK: - 通用行组件

struct SettingChip: View {
    let symbol: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.opacity(0.18))
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            )
    }
}

/// 一行设置：彩色图标 + 标题/副标题 + 右侧控件
struct SettingRow<Control: View>: View {
    let symbol: String
    var chip: Color = JB.green
    let title: String
    var subtitle: String?
    var subtitleTint: Color = JB.label
    var isLast = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SettingChip(symbol: symbol, color: chip)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(JB.value)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(subtitleTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 文字列优先拿宽度，否则中文说明会被右侧下拉挤成竖排
                .layoutPriority(1)

                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if !isLast {
                Rectangle().fill(JB.cardStroke).frame(height: 0.5).padding(.leading, 48)
            }
        }
    }
}

/// 分组容器（带可选的组标题）
struct SettingGroup<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    }
                    Text(title).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(JB.label)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SettingsStyle.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(JB.cardStroke, lineWidth: 0.5)
                )
        }
    }
}

/// 单选圆点（Juicy 的绿色对勾圆）
struct SettingRadio: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(selected ? JB.green : JB.faint)
    }
}

/// 统一风格的下拉
struct SettingPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var width: CGFloat = 128

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: width)
        // 系统默认用蓝色强调色，与本应用的绿冲突；开关已经染绿，下拉也跟上
        .tint(JB.green)
    }
}

/// 说明块（用来放"为什么这个开关不能给"这类必须说清楚的事）
struct SettingNote: View {
    let symbol: String
    let text: String
    var tint: Color = JB.orange

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.08))
        )
    }
}

// MARK: - 菜单栏

private struct MenuBarPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "图标形态", symbol: "menubar.rectangle") {
                ForEach(Array(AppSettings.MenuBarStyle.allCases.enumerated()), id: \.element.id) { idx, style in
                    SettingRow(symbol: style == .mark ? "bolt.fill" : "battery.100",
                               chip: JB.green,
                               title: style.title,
                               subtitle: style.subtitle,
                               isLast: idx == AppSettings.MenuBarStyle.allCases.count - 1) {
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { settings.menuBarStyle = style }
                        } label: {
                            SettingRadio(selected: settings.menuBarStyle == style)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            SettingGroup(title: "显示", symbol: "slider.horizontal.3") {
                SettingRow(symbol: "textformat.123", chip: JB.green,
                           title: "附加读数",
                           subtitle: settings.menuBarStyle.showsTrailing
                               ? "药丸右侧跟的那段文字"
                               : "当前形态不显示附加读数") {
                    SettingPicker(selection: $settings.trailing,
                                  options: AppSettings.Trailing.allCases.map { ($0, $0.title) })
                }
                SettingRow(symbol: "circle.lefthalf.filled", chip: JB.orange,
                           title: "配色档位",
                           subtitle: "菜单栏底色会跟随系统外观变化，也可钉死") {
                    SettingPicker(selection: $settings.palette,
                                  options: AppSettings.Palette.allCases.map { ($0, $0.title) })
                }
                SettingRow(symbol: "textformat.size", chip: JB.green,
                           title: "大小",
                           subtitle: "放大图标与文字，更易于阅读") {
                    SettingPicker(selection: $settings.iconSize,
                                  options: AppSettings.IconSize.allCases.map { ($0, $0.title) })
                }
                SettingRow(symbol: "leaf.fill", chip: JB.green,
                           title: "状态颜色",
                           subtitle: "充电时绿色，电量低时橙色与红色。关闭后保持中性，仅在电量极低时变红。",
                           isLast: true) {
                    Toggle("", isOn: $settings.statusColors)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.green)
                }
            }

            SettingGroup(title: "预览", symbol: "eye.fill") {
                MenuBarPreview(settings: settings, model: model)
            }
        }
    }
}

/// 预览卡：模拟一条菜单栏，把真实渲染的图标放进去（数据也是实时的）
private struct MenuBarPreview: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    private var isDark: Bool {
        switch settings.palette {
        case .light: return false
        case .dark:  return true
        case .automatic:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    var body: some View {
        let s = model.snapshot
        let tint = MenuBarTint.color(for: s, isDark: isDark, settings: settings)
        let style = settings.effectiveStyle
        let image = MenuBarIcon.render(for: s, style: style, tint: tint,
                                      height: settings.iconSize.pillHeight)
        let trailing = style.showsTrailing
            ? MenuBarText.trailing(settings: settings, snapshot: s)
            : ""

        HStack(spacing: 6) {
            Image(nsImage: image)
            if !trailing.isEmpty {
                Text(" " + trailing)
                    .font(.system(size: 11 * (settings.iconSize.pillHeight / 15), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: tint))
            }
            Spacer(minLength: 0)
            Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isDark ? Color(white: 0.16) : Color(white: 0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(JB.cardStroke, lineWidth: 0.5)
        )
        .padding(12)
    }
}

// MARK: - 提醒

private struct AlertsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "电源提示", symbol: "bell.badge.fill") {
                SettingRow(symbol: "capsule.fill", chip: JB.green,
                           title: "插拔电源提示",
                           subtitle: "接入 / 断开电源时在屏幕正上方弹一枚胶囊") {
                    Toggle("", isOn: $settings.toastEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.green)
                }
                SettingRow(symbol: "timer", chip: JB.green,
                           title: "停留时长",
                           subtitle: "超时后自动淡出，点一下可立即关闭",
                           isLast: true) {
                    SettingPicker(selection: $settings.toastSeconds,
                                  options: AppSettings.toastDurationChoices.map { ($0, "\(Int($0)) 秒") },
                                  width: 96)
                        .disabled(!settings.toastEnabled)
                }
            }

            SettingGroup(title: "告警", symbol: "exclamationmark.triangle.fill") {
                SettingRow(symbol: "battery.25percent", chip: JB.orange,
                           title: "电量偏低告警",
                           subtitle: "未接电源且电量跌破阈值时提示一次") {
                    Toggle("", isOn: $settings.lowBatteryAlert)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.orange)
                }
                SettingRow(symbol: "dial.low", chip: JB.orange,
                           title: "低电量阈值") {
                    SettingPicker(selection: $settings.lowBatteryThreshold,
                                  options: AppSettings.lowBatteryChoices.map { ($0, "\($0)%") },
                                  width: 96)
                        .disabled(!settings.lowBatteryAlert)
                }
                SettingRow(symbol: "bolt.slash.fill", chip: JB.orange,
                           title: "适配器功率不足",
                           subtitle: "插着电但电池仍在放电时提示一次") {
                    Toggle("", isOn: $settings.netDischargeAlert)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.orange)
                }
                SettingRow(symbol: "thermometer.high", chip: JB.red,
                           title: "电池高温告警",
                           subtitle: "温度超过阈值时提示一次") {
                    Toggle("", isOn: $settings.highTemperatureAlert)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.red)
                }
                SettingRow(symbol: "thermometer.medium", chip: JB.red,
                           title: "高温阈值",
                           isLast: true) {
                    SettingPicker(selection: $settings.highTemperatureThreshold,
                                  options: AppSettings.temperatureChoices.map { ($0, "\(Int($0)) °C") },
                                  width: 96)
                        .disabled(!settings.highTemperatureAlert)
                }
            }

            SettingNote(symbol: "info.circle.fill",
                        text: "三类告警每次启动最多各提示一次，避免在临界值附近反复弹。"
                            + "提示用的是本应用自己的胶囊，不经过系统通知中心，因此不需要通知权限。",
                        tint: JB.label)
        }
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "启动", symbol: "power") {
                SettingRow(symbol: "arrow.clockwise.circle.fill", chip: JB.green,
                           title: "开机自动启动",
                           subtitle: "登录后在菜单栏静默启动，不打开窗口",
                           isLast: true) {
                    Toggle("", isOn: Binding(get: { settings.launchAtLogin },
                                            set: { settings.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.green)
                }
            }

            if let note = settings.launchAtLoginNote {
                SettingNote(symbol: "exclamationmark.triangle.fill", text: note)
            }

            SettingGroup(title: "通知外观", symbol: "sparkles") {
                SettingRow(symbol: "capsule.fill", chip: JB.green,
                           title: "提醒气泡尺寸",
                           subtitle: "屏幕正上方那枚胶囊的图标与字号") {
                    SettingPicker(selection: $settings.toastSize,
                                  options: AppSettings.ToastSize.allCases.map { ($0, $0.title) })
                }
                SettingRow(symbol: "circle.dashed", chip: JB.orange,
                           title: "屏幕边缘光晕",
                           subtitle: "胶囊外侧叠一圈同色柔光，越强越像光洒在屏幕上") {
                    SettingPicker(selection: $settings.edgeGlow,
                                  options: AppSettings.EdgeGlow.allCases.map { ($0, $0.title) })
                }
                ToastAppearancePreview(settings: settings, model: model)
            }

            SettingGroup(title: "运行", symbol: "speedometer") {
                SettingRow(symbol: "timer", chip: JB.green,
                           title: "最近一次采样耗时",
                           subtitle: "读取 IORegistry + 公开 API + 进程能耗差分",
                           isLast: true) {
                    Text(String(format: "%.2f ms", model.lastSampleDurationMS))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
            }

            SettingGroup(title: "重置", symbol: "arrow.counterclockwise") {
                SettingRow(symbol: "arrow.counterclockwise", chip: JB.orange,
                           title: "恢复默认设置",
                           subtitle: "菜单栏形态、提醒与告警阈值、弹窗分区折叠状态全部还原",
                           isLast: true) {
                    Button("恢复默认") { confirmReset = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .alert("恢复默认设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { }
            Button("恢复", role: .destructive) { settings.resetAll() }
        } message: {
            Text("所有外观与提醒设置将回到出厂默认。")
        }
    }
}

/// 提醒外观的实时预览。渲染用的就是真弹出来那套 `StatusToastView`、数据取当下读数 ——
/// 预览里长什么样，屏幕上弹出来就是什么样，不存在"预览和实物两套画法"。
private struct ToastAppearancePreview: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    /// 预览里是否画光晕。**只影响这一张预览图**，真弹出来的胶囊一律按上面的档位走 ——
    /// 有它才能在不动设置的前提下对照"有光晕 / 没光晕"。
    @State private var showGlow = true

    private var spec: ToastSpec { ToastSpec.representative(from: model.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("预览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JB.label)
                Spacer(minLength: 0)
                Toggle("", isOn: $showGlow)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.green)
                Text("显示光晕（仅预览）")
                    .font(.system(size: 11))
                    .foregroundStyle(JB.label)
            }

            // 预览舞台 = 一块缩小的「屏幕」：顶边铺那条光带，里面放胶囊。
            // 光带用的是同一段渐变、同一个高度，只是画布小 —— 不另做一套示意画法。
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SettingsStyle.previewStage)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                ScreenEdgeGlowView(tint: StatusToastView.tint(for: spec),
                                   glow: showGlow ? settings.edgeGlow : .off)
                StatusToastView(spec: spec,
                                size: settings.toastSize,
                                glow: showGlow ? settings.edgeGlow : .off)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack {
                Spacer(minLength: 0)
                Button {
                    // 走真面板、真定位、真停留时长 —— 按钮弹出来的就是用户真会遇到的那一条
                    StatusToastController.shared.show(spec, seconds: settings.toastSeconds)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text("预览通知").font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - 充电

private struct ChargingPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "低电量模式", symbol: "leaf.fill") {
                SettingRow(symbol: "leaf.fill", chip: JB.green,
                           title: "低电量模式",
                           subtitle: model.lowPowerMode ? "已开启" : "已关闭",
                           isLast: true) {
                    Toggle("", isOn: Binding(get: { model.lowPowerMode },
                                            set: { model.setLowPowerMode($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(JB.green)
                }
            }

            if let hint = model.lowPowerModeHint {
                SettingNote(symbol: "lock.fill", text: hint)
            }

            SettingGroup(title: "充电上限", symbol: "battery.100percent.bolt") {
                SettingRow(symbol: "battery.100percent.bolt", chip: JB.orange,
                           title: "限制最高充电电量",
                           subtitle: "尚未实现 —— 需要写入 SMC，必须由 root helper 完成",
                           subtitleTint: JB.orange,
                           isLast: true) {
                    Text("规划中")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(JB.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(JB.orange.opacity(0.14)))
                }
            }

            SettingNote(symbol: "info.circle.fill",
                        text: "充电上限归入 P2：需要注册 root daemon + XPC 通信 + SMC 写入，"
                            + "与低电量模式的一键切换共用同一套特权通道。在拿到这条通道之前"
                            + "不会做成一个点了没反应的开关。",
                        tint: JB.label)

            SettingGroup(title: "系统", symbol: "gearshape.fill") {
                Button {
                    if let url = URL(string: SettingsLink.battery) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 8) {
                        SettingChip(symbol: "arrow.up.forward.app", color: JB.green)
                        Text("打开系统「电池」面板")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(JB.value)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10)).foregroundStyle(JB.faint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - App 用量

private struct UsagePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: PowerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "排行", symbol: "chart.bar.fill") {
                SettingRow(symbol: "list.number", chip: Color(nsColor: .adaptive(light: "#0A63C2", dark: "#4DA3FF")),
                           title: "显示条数",
                           subtitle: "弹窗「能耗排行」里最多列出的应用数",
                           isLast: true) {
                    SettingPicker(selection: $settings.energyRowCount,
                                  options: AppSettings.energyRowChoices.map { ($0, "\($0) 个") },
                                  width: 96)
                }
            }

            SettingGroup(title: "当前窗口", symbol: "clock") {
                SettingRow(symbol: "timer", chip: JB.green,
                           title: "采样窗口",
                           subtitle: "基线建立后：弹窗打开 2 秒一次，关闭 60 秒一次",
                           isLast: true) {
                    Text(String(format: "%.0f 秒", model.energy.windowSeconds))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
            }

            SettingNote(symbol: "lock.fill",
                        text: "能耗排行只能读到与当前应用同一个用户（uid）的进程。"
                            + "本次覆盖 \(model.energy.measuredProcessCount) 个进程，"
                            + "另有 \(model.energy.deniedProcessCount) 个其他用户的进程无权读取。"
                            + "合计值只占整机功耗的一小部分，界面里只用于相对比较，不当作绝对瓦数。",
                        tint: JB.label)
        }
    }
}

// MARK: - 电池（只读实时数据）

private struct BatteryPane: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "当前状态", symbol: "battery.100percent") {
                SettingRow(symbol: "battery.100", chip: JB.green,
                           title: "电量", subtitle: s.statusText) {
                    Text("\(s.percentage)%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(s.heroTint)
                }
                SettingRow(symbol: "thermometer.medium", chip: JB.orange,
                           title: "电池温度") {
                    Text(Fmt.temperature(s.batteryTemperatureC))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
                SettingRow(symbol: "waveform.path.ecg", chip: JB.green,
                           title: "健康度",
                           subtitle: s.healthCondition ?? s.batteryHealth) {
                    Text(Fmt.percent(s.healthPercent))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.greenText)
                }
                SettingRow(symbol: "arrow.triangle.2.circlepath", chip: JB.green,
                           title: "循环次数",
                           subtitle: "设计循环 \(s.designCycleCount.map(String.init) ?? "—")") {
                    Text(s.cycleCount.map(String.init) ?? "—")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
                SettingRow(symbol: "internaldrive", chip: JB.green,
                           title: "满充 / 设计容量",
                           subtitle: "满充容量会随衰减下降") {
                    Text("\(Fmt.capacity(s.maxCapacityMAH)) / \(Fmt.capacity(s.designCapacityMAH))")
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
                SettingRow(symbol: "cpu", chip: JB.green,
                           title: "主板侧输入",
                           subtitle: "来自 PowerTelemetryData") {
                    Text((s.systemVoltageInMV ?? 0) > 0
                         ? "\(Fmt.volts(s.systemVoltageInMV)) · \(Fmt.milliAmps(s.systemCurrentInMA))"
                         : "—")
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
                SettingRow(symbol: "square.stack.3d.up", chip: JB.green,
                           title: "电芯电压",
                           subtitle: "各串电压差异过大通常意味着电芯不均衡",
                           isLast: true) {
                    Text(s.cellVoltagesMV.isEmpty
                         ? "—"
                         : s.cellVoltagesMV.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " / ") + " V")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(JB.value)
                }
            }

            SettingNote(symbol: "clock",
                        text: "功率与电量由电量计提供，刷新周期为 60 秒 —— 这里的数字不会像电压那样每秒跳动，"
                            + "当前距上次采样 \(Fmt.age(seconds: s.secondsSinceGaugeUpdate))。",
                        tint: JB.label)
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon).resizable().frame(width: 52, height: 52)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(JB.green).frame(width: 52, height: 52)
                        .overlay(Image(systemName: "bolt.fill").font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wattup")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JB.value)
                    Text("版本 " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0")
                         + " · 仅本机、零网络请求")
                        .font(.system(size: 11))
                        .foregroundStyle(JB.label)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            SettingGroup(title: "数据来源", symbol: "waveform.path.ecg") {
                AboutLine(symbol: "cpu", title: "功率遥测", detail: "AppleSmartBattery 的 PowerTelemetryData")
                AboutLine(symbol: "bolt.fill", title: "电池端口径", detail: "Voltage × Amperage 交叉校验")
                AboutLine(symbol: "powerplug.fill", title: "适配器", detail: "IOPS 公开 API + AdapterDetails")
                AboutLine(symbol: "chart.bar.fill", title: "进程能耗", detail: "proc_pid_rusage(RUSAGE_INFO_V6) 差分", isLast: true)
            }

            SettingGroup(title: "已知限制", symbol: "exclamationmark.triangle.fill") {
                AboutLine(symbol: "lock.fill", title: "跨用户进程不可读", detail: "权限边界严格等价于同 uid")
                AboutLine(symbol: "timer", title: "电量计 60 秒刷新", detail: "界面所有功率值都标注采样时间")
                AboutLine(symbol: "battery.0percent", title: "充电上限未实现", detail: "需要 root helper 写 SMC")
                AboutLine(symbol: "envelope.fill", title: "数据不出本机", detail: "无网络请求、无遥测上报", isLast: true)
            }

            SettingGroup(title: "操作", symbol: "gearshape.fill") {
                Button {
                    if let url = URL(string: SettingsLink.battery) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 8) {
                        SettingChip(symbol: "arrow.up.forward.app", color: JB.green)
                        Text("打开系统「电池」面板")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(JB.value)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").font(.system(size: 10)).foregroundStyle(JB.faint)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(JB.cardStroke).frame(height: 0.5).padding(.leading, 48)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 8) {
                        SettingChip(symbol: "power", color: JB.red)
                        Text("退出 Wattup")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(JB.red)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AboutLine: View {
    let symbol: String
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(JB.label)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(JB.value)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(JB.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !isLast {
                Rectangle().fill(JB.cardStroke).frame(height: 0.5).padding(.leading, 38)
            }
        }
    }
}
