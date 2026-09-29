import AppKit

/// 按 Juicy 的菜单栏语言自绘状态项图标。
///
/// Juicy 的形态是「[闪电] + [圆角描边药丸，内含数字]」，配色按状态走绿 / 橙 / 红三档。
/// 这里不用 SF Symbol 直接填色，而是自己画路径 —— 模板图会被系统强制单色，
/// 而我们要的就是**保留颜色**（这是 Juicy 视觉识别的核心）。
enum MenuBarIcon {

    /// 闪电多边形，坐标归一化到 0...1 的方框内
    private static let boltPoints: [CGPoint] = [
        CGPoint(x: 0.62, y: 0.00),
        CGPoint(x: 0.10, y: 0.58),
        CGPoint(x: 0.42, y: 0.58),
        CGPoint(x: 0.34, y: 1.00),
        CGPoint(x: 0.90, y: 0.40),
        CGPoint(x: 0.56, y: 0.40),
    ]

    /// - Parameters:
    ///   - number: 药丸里的数字（电量百分比）
    ///   - tint: 状态色
    ///   - showsBolt: 充电中在药丸前加闪电
    ///   - height: 药丸高度，默认贴合菜单栏
    /// - Returns: 非模板图片，调用方**不要**再设 `isTemplate = true`
    static func pill(number: String?,
                     tint: NSColor,
                     showsBolt: Bool,
                     height: CGFloat = 15) -> NSImage {

        let font = NSFont.monospacedDigitSystemFont(ofSize: height * 0.6, weight: .bold)
        let textWidth: CGFloat = number.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        } ?? 0

        let pillH = height
        // 横向留白比 Juicy 再宽一点，两位数字才不会顶到边
        let pillW = number == nil ? 0 : max(pillH * 1.5, textWidth + pillH * 1.1)
        let boltH = height * 1.0
        let boltW = showsBolt ? boltH * 0.62 : 0
        let gap: CGFloat = (showsBolt && number != nil) ? 3.5 : 0

        let totalW = boltW + gap + pillW
        let totalH = height

        // Juicy 的药丸是实心状态色 + 白色数字 + 一圈更亮的外环。
        // 纯亮绿底配白字在深色菜单栏上对比偏低，所以底子略压深一档，
        // 再给白字加一层暗色描边，保证两种外观下都读得清。
        let fill = tint.blended(withFraction: 0.16, of: .black) ?? tint
        let rim = tint.blended(withFraction: 0.5, of: .white) ?? tint

        let image = NSImage(size: NSSize(width: max(totalW, 6), height: totalH), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            var x: CGFloat = 0
            let midY = totalH / 2

            // 闪电
            if showsBolt {
                let path = CGMutablePath()
                for (i, p) in boltPoints.enumerated() {
                    let pt = CGPoint(x: x + p.x * boltW, y: midY - boltH / 2 + (1 - p.y) * boltH)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(tint.cgColor)
                ctx.fillPath()
                x += boltW + gap
            }

            // 药丸
            if number != nil {
                let inset: CGFloat = 1.1
                let rect = CGRect(x: x + inset, y: inset,
                                  width: pillW - inset * 2, height: pillH - inset * 2)
                let radius = rect.height * 0.42
                let pill = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                                  transform: nil)

                ctx.addPath(pill)
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()

                ctx.addPath(pill)
                ctx.setStrokeColor(rim.cgColor)
                ctx.setLineWidth(1.35)
                ctx.strokePath()

                // 数字：白色，先描一层暗色再压白字 —— Juicy 的白字之所以读得清就靠这个
                let str = number! as NSString
                let size = str.size(withAttributes: [.font: font])
                let origin = CGPoint(x: rect.midX - size.width / 2,
                                     y: rect.midY - size.height / 2 + 0.4)

                let shadowAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: fill.blended(withFraction: 0.55, of: .black) ?? .black,
                    .strokeWidth: -3.0,
                    .strokeColor: fill.blended(withFraction: 0.55, of: .black) ?? .black,
                ]
                str.draw(at: origin, withAttributes: shadowAttrs)

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ]
                str.draw(at: origin, withAttributes: attrs)
            }

            return true
        }
        return image
    }

    /// 按设置里的形态渲染状态项图标。三种形态的唯一出口 —— 状态项与设置预览共用，
    /// 免得两处各画一套、结果长得不一样。
    static func render(for snapshot: BatterySnapshot,
                       style: AppSettings.MenuBarStyle,
                       tint: NSColor,
                       height: CGFloat) -> NSImage {
        switch style {
        case .mark:
            // 「仅标志」画的是**品牌标记**而不是状态图标：闪电是标记的一部分，常驻。
            // 状态改为只用颜色表达，设置面板里写清楚了这一点。
            return mark(tint: tint, height: height)
        default:
            let number = style.showsNumber && snapshot.hasBattery ? "\(snapshot.percentage)" : nil
            return pill(number: number, tint: tint, showsBolt: snapshot.isCharging, height: height)
        }
    }

    /// 品牌标记：圆角方块 + 白闪电，观感与应用图标一致
    static func mark(tint: NSColor, height: CGFloat) -> NSImage {
        let fill = tint.blended(withFraction: 0.16, of: .black) ?? tint
        let rim = tint.blended(withFraction: 0.5, of: .white) ?? tint

        return NSImage(size: NSSize(width: height, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset: CGFloat = 1
            let rect = CGRect(x: inset, y: inset,
                              width: height - inset * 2, height: height - inset * 2)
            let radius = rect.height * 0.26
            let box = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                             transform: nil)
            ctx.addPath(box); ctx.setFillColor(fill.cgColor); ctx.fillPath()
            ctx.addPath(box); ctx.setStrokeColor(rim.cgColor); ctx.setLineWidth(1.3); ctx.strokePath()

            let inner = rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.20)
            let bolt = CGMutablePath()
            for (i, p) in boltPoints.enumerated() {
                let pt = CGPoint(x: inner.minX + p.x * inner.width,
                                 y: inner.minY + (1 - p.y) * inner.height)
                if i == 0 { bolt.move(to: pt) } else { bolt.addLine(to: pt) }
            }
            bolt.closeSubpath()
            ctx.addPath(bolt); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
            return true
        }
    }

    /// 自检用：把几种状态的图标并排渲染成一张带说明的图。
    ///
    /// 存在的意义：闪电「该不该出现」这件事，真机上要等到充电状态变化才能肉眼比对，
    /// 而把 `isCharging` / `isFullyCharged` 两组状态一次性画出来，一眼就能看出
    /// 闪电是不是只在 isCharging 时出现 —— 不用拔电源去赌。
    ///
    /// `style` / `height` 让这张图跟着当前设置走：形态和大小改了以后，
    /// 对照图必须跟着改，否则它验证的就不是用户看到的那套渲染。
    static func debugStrip(isDark: Bool,
                           style: AppSettings.MenuBarStyle = .batteryIndicator,
                           height: CGFloat = 30,
                           rows: [(label: String, snapshot: BatterySnapshot)]) -> NSImage {
        let rowHeight: CGFloat = height + 16
        let font = NSFont.systemFont(ofSize: 13)

        let items: [(NSImage, String)] = rows.map { row in
            // 对照图固定按「状态颜色开」渲染 —— 这张图的目的就是核对状态色与闪电条件
            let tint = MenuBarTint.color(for: row.snapshot, isDark: isDark, statusColors: true)
            // 这一行就是被测逻辑本身：闪电只由 isCharging 决定
            let image = render(for: row.snapshot, style: style, tint: tint, height: height)
            return (image, row.label)
        }

        let textWidth = items.map {
            ($0.1 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 200
        let maxPillWidth = items.map { $0.0.size.width }.max() ?? 40
        let width = 24 + maxPillWidth + 16 + textWidth + 24
        let height = CGFloat(items.count) * rowHeight + 20

        let background = isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        let textColor = isDark ? NSColor.white : NSColor.black

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            for (i, item) in items.enumerated() {
                let centerY = 10 + CGFloat(i) * rowHeight + rowHeight / 2
                let pill = item.0
                pill.draw(in: NSRect(x: 24, y: centerY - pill.size.height / 2,
                                     width: pill.size.width, height: pill.size.height))
                (item.1 as NSString).draw(
                    at: NSPoint(x: 24 + maxPillWidth + 16, y: centerY - 8),
                    withAttributes: [.font: font, .foregroundColor: textColor])
            }
            return true
        }
    }
}

enum MenuBarTint {

    /// 用哪一套档位。`palette` 设成「自动」时跟随系统外观。
    @MainActor
    static func isDark(_ settings: AppSettings) -> Bool {
        switch settings.palette {
        case .light:     return false
        case .dark:      return true
        case .automatic:
            return NSApp.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    @MainActor
    static func color(for snapshot: BatterySnapshot,
                      isDark: Bool,
                      settings: AppSettings) -> NSColor {
        color(for: snapshot, isDark: isDark, statusColors: settings.statusColors)
    }

    /// 纯函数版本：状态项、设置里的预览、自检对照图都走这里，保证三处配色一致。
    /// 不依赖设置单例，所以自检脚本能在没有 UI 的时候直接调。
    static func color(for snapshot: BatterySnapshot,
                      isDark: Bool,
                      statusColors: Bool) -> NSColor {
        let green = isDark ? NSColor(hex: "#00D832") : NSColor(hex: "#00A32B")
        let orange = isDark ? NSColor(hex: "#FF8A00") : NSColor(hex: "#B4650A")
        let red = isDark ? NSColor(hex: "#FF453A") : NSColor(hex: "#CE0014")
        let gray = isDark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.35, alpha: 1)

        guard snapshot.hasBattery else { return gray }

        // 「状态颜色」关掉后图标保持中性，只在电量极低时变红
        guard statusColors else {
            return snapshot.percentage <= 5 ? red : gray
        }

        // 插着电却在净放电是告警语义，优先级最高，不受其他档位影响
        if snapshot.isNetDischargingWhilePlugged { return orange }
        if snapshot.percentage <= 10 { return red }
        if snapshot.percentage <= 25 { return orange }
        return green
    }
}

// MARK: - 菜单栏附加读数

/// 药丸右边那段文字。抽出来是为了让状态项与设置预览用同一份口径。
enum MenuBarText {
    @MainActor
    static func trailing(settings: AppSettings, snapshot s: BatterySnapshot) -> String {
        switch settings.trailing {
        case .none:
            return ""
        case .percentage:
            return s.hasBattery ? "\(s.percentage)%" : "AC"
        case .wattage:
            guard let w = s.batteryNetWatts else { return s.hasBattery ? "\(s.percentage)%" : "AC" }
            return String(format: "%.1fW", abs(w))
        case .timeRemaining:
            if s.isCharging, let t = s.timeToFullMinutes { return Fmt.compactMinutes(t) }
            if let t = s.timeToEmptyMinutes { return Fmt.compactMinutes(t) }
            return s.hasBattery ? "\(s.percentage)%" : "AC"
        }
    }
}
