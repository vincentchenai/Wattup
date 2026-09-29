import SwiftUI
import AppKit

// MARK: - 颜色工具

extension NSColor {
    /// 从 "#00D832" 构造
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 同一个语义色在浅色 / 深色外观下各取一套值。
    /// 深色沿用 Juicy 官方配色，浅色提高对比度以适配白底。
    static func adaptive(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

// MARK: - 主题令牌

/// Juicy 色板。取色来源：官方界面图实测采样 ——
/// 绿 `#00D832`、橙 `#FF8A00`、红 `#FE0033`、深色卡片底 `#1C2023`、胶囊底 `#111111`。
///
/// 全部用计算属性而不是 `static let`：`NSColor` 不是 `Sendable`，
/// 用计算属性可以避开 Swift 6 的全局状态检查。
enum JB {

    // MARK: 状态色（Juicy 的绿 / 橙 / 红三档）

    /// 主色。进度条、环形、图标、大号数字都用它
    static var green: Color {
        Color(nsColor: .adaptive(light: "#00B02E", dark: "#00D832"))
    }
    /// 小字号绿字需要更高对比度
    static var greenText: Color {
        Color(nsColor: .adaptive(light: "#06812A", dark: "#3BE061"))
    }
    static var greenSoft: Color {
        Color(nsColor: .adaptive(light: "#00B02E", dark: "#00D832")).opacity(0.16)
    }

    static var orange: Color {
        Color(nsColor: .adaptive(light: "#C2710A", dark: "#FF8A00"))
    }
    static var orangeSoft: Color { orange.opacity(0.14) }

    static var red: Color {
        Color(nsColor: .adaptive(light: "#D70015", dark: "#FF453A"))
    }
    static var redSoft: Color { red.opacity(0.14) }

    /// 中位 / 未强调数据用中性色，避免整屏都在喊
    static var neutral: Color {
        Color(nsColor: .adaptive(light: "#A8A8AE", dark: "#5C6469"))
    }

    // MARK: 表面

    static var cardFill: Color {
        Color(nsColor: .adaptive(light: "#FFFFFF", dark: "#1C2023"))
    }
    /// 卡片描边。浅色下发丝边框，深色下极弱高光
    static var cardStroke: Color {
        Color(nsColor: .adaptive(light: "#E6E6EB", dark: "#2B3235"))
    }
    /// 进度条轨道
    static var track: Color {
        Color(nsColor: .adaptive(light: "#E9E9EE", dark: "#2E3437"))
    }
    /// 深色卡片内部再降一级的底（Juicy 的胶囊底 #111111）
    static var insetFill: Color {
        Color(nsColor: .adaptive(light: "#F5F5F7", dark: "#14181A"))
    }

    // MARK: 文字

    static var label: Color {
        Color(nsColor: .adaptive(light: "#8A8A8E", dark: "#9BA3A7"))
    }
    static var value: Color {
        Color(nsColor: .adaptive(light: "#1C1C1E", dark: "#FFFFFF"))
    }
    static var faint: Color {
        Color(nsColor: .adaptive(light: "#B4B4B9", dark: "#6E767A"))
    }

    // MARK: 版式常量

    /// 大写微标签（Juicy 的 "UNTIL FULL" / "HEALTH"）
    static let microTracking: CGFloat = 0.6
}

// MARK: - 状态 → 颜色映射

extension BatterySnapshot {
    /// 电量档位色：Juicy 的绿 / 橙 / 红三档
    var levelTint: Color {
        if !hasBattery { return JB.neutral }
        if isNetDischargingWhilePlugged { return JB.orange }
        if percentage <= 10 { return JB.red }
        if percentage <= 25 { return JB.orange }
        return JB.green
    }

    /// 英雄数字的颜色：充电中一定是绿（Juicy 语义），
    /// 否则按电量档位，插电净放电时用橙告警
    var heroTint: Color {
        if !hasBattery { return JB.neutral }
        if isNetDischargingWhilePlugged { return JB.orange }
        if isCharging || isFullyCharged { return JB.green }
        return levelTint
    }

    /// 主操作状态（Juicy 的 "Charging" + 电池图标芯片）
    var stateSymbol: String {
        if !hasBattery { return "powerplug.fill" }
        if isNetDischargingWhilePlugged { return "exclamationmark.triangle.fill" }
        if isFullyCharged { return "checkmark.circle.fill" }
        if isCharging { return "bolt.fill" }
        return "arrow.down.circle.fill"
    }

    /// 英雄卡下方的短说明
    var heroCaption: String {
        if !hasBattery { return isExternalConnected ? "外接电源" : "无电池" }
        if isNetDischargingWhilePlugged { return "插着电，但电量仍在下降" }
        if isCharging, let t = timeToFullMinutes { return "\(Fmt.duration(t)) 充满" }
        if isCharging { return "充电中" }
        if isFullyCharged && !isExternalConnected { return "满电 · 电池供电" }
        if isFullyCharged { return "已充满" }
        if let t = timeToEmptyMinutes { return "\(Fmt.duration(t)) 耗尽" }
        return statusText
    }
}
