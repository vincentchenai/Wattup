import Foundation

enum Fmt {

    /// 18.34 -> "18.3 W"
    static func watts(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f W", value)
    }

    /// 253 -> "253 mW"
    static func milliWatts(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.2f W", value / 1000) }
        if value >= 10 { return String(format: "%.0f mW", value) }
        return String(format: "%.1f mW", value)
    }

    /// 12525 -> "12.53 V"
    static func volts(_ millivolts: Int?) -> String {
        guard let millivolts else { return "—" }
        return String(format: "%.2f V", Double(millivolts) / 1000)
    }

    /// 197 -> "+197 mA"（正号代表充电）
    static func signedMilliAmps(_ value: Int?) -> String {
        guard let value else { return "—" }
        return String(format: "%+d mA", value)
    }

    static func milliAmps(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value) mA"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.1f °C", celsius)
    }

    /// 169 -> "2:49"
    static func minutes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        let h = value / 60
        let m = value % 60
        return String(format: "%d:%02d", h, m)
    }

    /// 时长说人话：169 -> "2 时 49 分"，25 -> "25 分"。
    /// 英雄数字旁边用这个，避免 "0:25" 被误读成时刻。
    static func duration(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        let h = value / 60
        let m = value % 60
        if h == 0 { return "\(m) 分" }
        if m == 0 { return "\(h) 时" }
        return "\(h) 时 \(m) 分"
    }

    /// 菜单栏专用：169 -> "2h49m"，25 -> "25m"。
    /// 菜单栏横向空间按像素算，不能写「2 时 49 分」。
    static func compactMinutes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "" }
        let h = value / 60
        let m = value % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h\(m)m"
    }

    static func capacity(_ mah: Int?) -> String {
        guard let mah else { return "—" }
        return "\(mah) mAh"
    }

    static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    /// 采样时间：只讲实话，直接说多少秒前
    static func age(seconds: Int?) -> String {
        guard let seconds else { return "未知" }
        if seconds < 2 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    /// 0x7008 之类的型号
    static func hex(_ value: Int?) -> String {
        guard let value else { return "—" }
        return String(format: "0x%04X", value)
    }
}
