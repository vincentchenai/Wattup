import Foundation
import SwiftUI
import ServiceManagement

/// 应用设置总闸。全部落 `UserDefaults`，改了立刻生效。
///
/// 分组理由：**菜单栏外观那几项必须能被 `refreshStatusItem` 在每次采样时同步读到**，
/// 所以不做异步、不缓存副本，直接读单例的属性；提醒与行为项由 `PowerModel` 在采样时消费。
///
/// 这里的每个开关都对应真实实现。做不到的能力（如充电上限需要 root）不放进模型，
/// 由设置面板显式标注原因 —— 宁可少一个开关，也不要一个点了没反应的开关。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - 枚举

    /// 菜单栏图标形态。命名对齐 Juicy 的三档。
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case batteryIndicator
        case minimal
        case mark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .batteryIndicator: return "电池指示器"
            case .minimal:          return "极简"
            case .mark:             return "仅标志"
            }
        }

        var subtitle: String {
            switch self {
            case .batteryIndicator: return "药丸显示电量，右侧跟一段附加读数"
            case .minimal:          return "只留电池药丸，不跟附加读数"
            case .mark:             return "只画一枚标志，占地最小，最不容易被系统挤掉"
            }
        }

        /// 只有「电池指示器」档才跟附加读数
        var showsTrailing: Bool { self == .batteryIndicator }
        /// 药丸里的数字
        var showsNumber: Bool { self != .mark }
    }

    /// 附加读数显示什么
    enum Trailing: String, CaseIterable, Identifiable {
        case wattage, percentage, timeRemaining, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .wattage:       return "瓦数"
            case .percentage:    return "电量百分比"
            case .timeRemaining: return "剩余时长"
            case .none:          return "不显示"
            }
        }
    }

    /// 图标用哪一套配色档位。菜单栏底色会跟着系统外观变，这里允许手动钉死。
    enum Palette: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "自动"
            case .light:     return "浅色菜单栏"
            case .dark:      return "深色菜单栏"
            }
        }
    }

    /// Juicy 的「大小」档：放大图标与文字，更易于阅读
    enum IconSize: String, CaseIterable, Identifiable {
        case small, regular, large
        var id: String { rawValue }

        var title: String {
            switch self {
            case .small:   return "小"
            case .regular: return "默认"
            case .large:   return "大"
            }
        }

        /// 药丸高度（pt）
        var pillHeight: CGFloat {
            switch self {
            case .small:   return 13
            case .regular: return 15
            case .large:   return 18
            }
        }
    }

    // MARK: - 提醒外观

    /// 提醒气泡（屏幕正上方那枚胶囊）的尺寸档位，对齐 Juicy 的「提醒气泡尺寸」。
    enum ToastSize: String, CaseIterable, Identifiable {
        case compact, regular, roomy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .compact: return "紧凑"
            case .regular: return "默认"
            case .roomy:   return "宽松"
            }
        }
    }

    /// 胶囊外侧同色柔光的强度。Juicy 面板里叫「屏幕边缘光晕」。
    enum EdgeGlow: String, CaseIterable, Identifiable {
        case off, regular, strong
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off:     return "关闭"
            case .regular: return "默认"
            case .strong:  return "强烈"
            }
        }
    }

    // MARK: - 菜单栏外观

    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var trailing: Trailing {
        didSet { UserDefaults.standard.set(trailing.rawValue, forKey: "menuBarTrailing") }
    }
    @Published var palette: Palette {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: "menuBarPalette") }
    }
    @Published var iconSize: IconSize {
        didSet { UserDefaults.standard.set(iconSize.rawValue, forKey: "menuBarIconSize") }
    }

    /// Juicy 的「状态颜色」开关：关掉后图标保持中性，只有电量极低时才变红
    @Published var statusColors: Bool { didSet { UserDefaults.standard.set(statusColors, forKey: "statusColors") } }

    /// 命令行临时覆盖形态，不写 UserDefaults（截图自检用）
    var transientStyle: MenuBarStyle?

    var effectiveStyle: MenuBarStyle { transientStyle ?? menuBarStyle }

    // MARK: - 提醒

    @Published var toastEnabled: Bool { didSet { UserDefaults.standard.set(toastEnabled, forKey: "plugToastEnabled") } }
    @Published var toastSeconds: Double { didSet { UserDefaults.standard.set(toastSeconds, forKey: "toastSeconds") } }

    /// 胶囊尺寸与外侧柔光强度。这两项只影响「长什么样」，不影响什么时候弹。
    @Published var toastSize: ToastSize { didSet { UserDefaults.standard.set(toastSize.rawValue, forKey: "toastSize") } }
    @Published var edgeGlow: EdgeGlow { didSet { UserDefaults.standard.set(edgeGlow.rawValue, forKey: "toastEdgeGlow") } }

    @Published var lowBatteryAlert: Bool { didSet { UserDefaults.standard.set(lowBatteryAlert, forKey: "lowBatteryAlert") } }
    @Published var lowBatteryThreshold: Int { didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") } }

    @Published var netDischargeAlert: Bool { didSet { UserDefaults.standard.set(netDischargeAlert, forKey: "netDischargeAlert") } }

    @Published var highTemperatureAlert: Bool { didSet { UserDefaults.standard.set(highTemperatureAlert, forKey: "highTemperatureAlert") } }
    @Published var highTemperatureThreshold: Double { didSet { UserDefaults.standard.set(highTemperatureThreshold, forKey: "highTemperatureThreshold") } }

    static let lowBatteryChoices = [10, 15, 20, 25, 30]
    static let temperatureChoices: [Double] = [40, 45, 50, 55]
    static let toastDurationChoices: [Double] = [3, 5, 8, 12]

    // MARK: - 用量

    @Published var energyRowCount: Int { didSet { UserDefaults.standard.set(energyRowCount, forKey: "energyRowCount") } }
    static let energyRowChoices = [3, 5, 8]

    // MARK: - 通用

    /// 开机自启。真实状态以 `SMAppService.mainApp.status` 为准，不用本地布尔值假装。
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginNote: String?

    // MARK: - 初始化

    private init() {
        let d = UserDefaults.standard

        // 从旧键迁移（旧版只有 menuBarDisplayMode 三档）
        if let legacy = d.string(forKey: "menuBarDisplayMode"), d.string(forKey: "menuBarStyle") == nil {
            let migrated: MenuBarStyle = switch legacy {
            case "percentage": .minimal
            case "iconOnly":   .mark
            default:           .batteryIndicator
            }
            menuBarStyle = migrated
        } else {
            menuBarStyle = Self.load("menuBarStyle", .batteryIndicator)
        }

        trailing = Self.load("menuBarTrailing", .wattage)
        palette = Self.load("menuBarPalette", .automatic)
        iconSize = Self.load("menuBarIconSize", .regular)

        statusColors = d.object(forKey: "statusColors") as? Bool ?? true

        toastEnabled = d.object(forKey: "plugToastEnabled") as? Bool ?? true
        toastSeconds = d.object(forKey: "toastSeconds") as? Double ?? 5
        toastSize = Self.load("toastSize", .regular)
        edgeGlow = Self.load("toastEdgeGlow", .regular)

        lowBatteryAlert = d.object(forKey: "lowBatteryAlert") as? Bool ?? true
        lowBatteryThreshold = d.object(forKey: "lowBatteryThreshold") as? Int ?? 20
        netDischargeAlert = d.object(forKey: "netDischargeAlert") as? Bool ?? true
        highTemperatureAlert = d.object(forKey: "highTemperatureAlert") as? Bool ?? true
        highTemperatureThreshold = d.object(forKey: "highTemperatureThreshold") as? Double ?? 45

        energyRowCount = d.object(forKey: "energyRowCount") as? Int ?? 5

        refreshLaunchAtLogin()
    }

    // MARK: - 开机自启

    /// 读系统里的真实注册状态。ad-hoc 签名 / 未放进「应用程序」目录时注册可能失败，
    /// 那种情况要如实报出来，不能只留一个勾。
    func refreshLaunchAtLogin() {
        let registered = SMAppService.mainApp.status == .enabled
        launchAtLogin = registered
        if registered {
            launchAtLoginNote = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginNote = "系统未接受注册：\(error.localizedDescription)"
        }

        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status != .enabled && enabled {
            launchAtLoginNote = launchAtLoginNote
                ?? "系统返回状态为「\(Self.describe(status))」，注册未生效。"
                + "应用需要放在「应用程序」目录并以 Developer ID 签名后才稳定。"
        } else if !enabled {
            launchAtLoginNote = nil
        }
        objectWillChange.send()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:          return "已启用"
        case .notRegistered:    return "未注册"
        case .notFound:         return "未找到"
        case .requiresApproval: return "等待用户在系统设置中批准"
        @unknown default:       return "未知"
        }
    }

    // MARK: - 重置

    func resetAll() {
        let keys = [
            "menuBarStyle", "menuBarTrailing", "menuBarPalette", "menuBarIconSize", "statusColors",
            "plugToastEnabled", "toastSeconds", "toastSize", "toastEdgeGlow",
            "lowBatteryAlert", "lowBatteryThreshold",
            "netDischargeAlert", "highTemperatureAlert", "highTemperatureThreshold",
            "energyRowCount", "menuBarDisplayMode",
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // 折叠状态一并还原，避免"重置了但弹窗还是老样子"
        for id in ["flow", "health", "adapter", "energy"] {
            UserDefaults.standard.removeObject(forKey: "section.\(id).expanded")
        }
        transientStyle = nil

        menuBarStyle = .batteryIndicator
        trailing = .wattage
        palette = .automatic
        iconSize = .regular
        statusColors = true
        toastEnabled = true
        toastSeconds = 5
        toastSize = .regular
        edgeGlow = .regular
        lowBatteryAlert = true
        lowBatteryThreshold = 20
        netDischargeAlert = true
        highTemperatureAlert = true
        highTemperatureThreshold = 45
        energyRowCount = 5
        objectWillChange.send()
    }

    // MARK: - 持久化小工具

    private static func load<T: RawRepresentable>(_ key: String, _ fallback: T) -> T
    where T.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key), let v = T(rawValue: raw) else {
            return fallback
        }
        return v
    }
}
