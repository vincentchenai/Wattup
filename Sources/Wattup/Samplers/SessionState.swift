import AppKit
import CoreGraphics

/// 「菜单栏此刻画不画」的运行时判据。
///
/// 存在的理由：`NSStatusItem.button.window.occlusionState` 在锁屏 / 显示器休眠 / 屏保
/// 期间**必然是 `false`** —— 那是系统整条菜单栏都不绘制，不是「我们的图标被藏了」。
/// 自检若只看 `occlusionState` 就会把锁屏误报成图标缺陷（实测踩过：凌晨锁屏跑
/// `--verify-statusitem`，拿到 false，白查了一轮覆盖区/autosaveName 的落位逻辑）。
/// 这里把两类判据分开提供，让自检自己说清是哪种情况。
enum SessionState {

    /// 屏幕是否处于锁屏状态。`CGSSessionScreenIsLocked` 由 loginwindow 置位，
    /// 是 CGSession 字典里公开可读的键。
    static var isScreenLocked: Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// 主显示器是否已休眠。
    static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 屏保是否正在运行。
    static var isScreenSaverRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
    }

    /// 前台应用的 bundle id（锁屏时是 `com.apple.loginwindow`）。
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 菜单栏此刻是否会被正常绘制。三个「屏幕不亮」状态任一成立 → 不绘制。
    static var isMenuBarDrawn: Bool {
        !(isScreenLocked || isDisplayAsleep || isScreenSaverRunning)
    }

    /// 造成「菜单栏不绘制」的原因，供自检打印；正常时为空。
    static var suppressedReason: String? {
        var reasons: [String] = []
        if isScreenLocked { reasons.append("屏幕已锁定") }
        if isDisplayAsleep { reasons.append("显示器已休眠") }
        if isScreenSaverRunning { reasons.append("屏保运行中") }
        return reasons.isEmpty ? nil : reasons.joined(separator: " + ")
    }

    /// 自检输出用的一行摘要。
    static var summary: String {
        var parts: [String] = []
        parts.append("锁屏=\(isScreenLocked ? "是" : "否")")
        parts.append("显示器休眠=\(isDisplayAsleep ? "是" : "否")")
        parts.append("屏保=\(isScreenSaverRunning ? "是" : "否")")
        parts.append("前台=\(frontmostBundleID ?? "nil")")
        return parts.joined(separator: "  ")
    }
}

/// 状态项是否可见的判定结论。
///
/// 抽成纯函数的原因：判据有三条分支（屏幕未亮 → 无法判定；屏幕亮且可见 → 通过；
/// 屏幕亮却不可见 → 真缺陷），而**锁屏期间只能走到第一条**，后两条没法在真机上随手覆盖。
/// 纯函数化之后可以用 `--selfcheck-statusitem-verdict` 把三条都实打实跑一遍，
/// 避免这条判定逻辑本身悄悄退化。
enum StatusItemVerdict {

    struct Input {
        /// `SessionState.isMenuBarDrawn`
        var menuBarDrawn: Bool
        /// 屏幕未亮的原因，用于文案
        var suppressedReason: String?
        /// `button.window?.occlusionState.contains(.visible)`
        var iconVisible: Bool
        /// 状态项是否落在刘海右侧可用区
        var onRightSide: Bool
        /// 静态落位证据（窗口坐标 vs 刘海右侧可用区）。不受屏幕是否点亮影响，
        /// 因此锁屏时它是唯一还能拿到的落位信息。
        var positionEvidence: String? = nil
    }

    static func evaluate(_ i: Input) -> String {
        if !i.menuBarDrawn {
            var s = "○ 本次自检无法判定图标可见性：\(i.suppressedReason ?? "屏幕未亮")，菜单栏整体不绘制。"
                + "此状态下 occlusionState=false 与 layer=25 窗口数=0 都是预期值。"
            if let e = i.positionEvidence {
                s += "\n   可用的静态证据：\(e)"
            } else {
                s += "\n   要验证落位请在屏幕点亮且未锁定时重跑本自检。"
            }
            return s
        }
        if i.iconVisible {
            return "✓ 图标可见。occlusionState=true，状态项已落在菜单栏可用区内（右侧=\(i.onRightSide)）。"
        }
        return "✗ 屏幕正常但图标未被绘制 —— 这是真的落位问题。\n"
            + "   排查顺序：autosaveName 的 NSStatusItem Preferred Position 键是否已播种 → 覆盖区宽度是否够 → "
            + "是否有其它应用抢占了状态区左端。"
    }
}
