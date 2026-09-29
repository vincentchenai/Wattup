import SwiftUI
import AppKit

// MARK: - 微标签（Juicy 的 "UNTIL FULL" / "HEALTH"）

struct MicroLabel: View {
    let text: String
    var tint: Color = JB.label

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(JB.microTracking)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

// MARK: - 卡片容器

struct CardBox<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(JB.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(JB.cardStroke, lineWidth: 0.5)
            )
    }
}

// MARK: - 图标状态芯片（Juicy 的「电池图标 + Charging」）

struct StateChip: View {
    let symbol: String
    let text: String
    var tint: Color = JB.green
    /// 充电中让闪电持续脉冲，这是「动」的部分
    var pulses = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous).fill(tint.opacity(0.13))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
    }
}

// MARK: - Juicy 粗进度条

/// Juicy 的进度条：圆角厚条 + 深色轨道 + 可选的闪电起点 + 限值刻度。
/// 填充宽度变化时走平滑动画，所以数据一刷新就能看见它「长过去」。
struct JuicyBar: View {
    /// 0...1
    let fraction: Double
    var tint: Color = JB.green
    var height: CGFloat = 9
    /// 充电中：条内持续流动的高光
    var flows = false
    /// 限值刻度位置（0...1），比如 80% 充电上限
    var tick: Double?

    @State private var flowPhase: CGFloat = 0

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(JB.track)

                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(height, w * clamped))
                    .overlay(alignment: .leading) {
                        if flows {
                            // 沿条流动的高光：一条窄的白色渐变
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                                        startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: max(18, w * clamped * 0.34))
                                .offset(x: flowPhase * max(1, w * clamped))
                                .blendMode(.plusLighter)
                                .clipShape(Capsule(style: .continuous))
                        }
                    }

                if let tick {
                    Capsule(style: .continuous)
                        .fill(JB.value.opacity(0.55))
                        .frame(width: 2.5, height: height + 5)
                        .offset(x: min(max(0, w * tick - 1.25), w - 2.5), y: -2.5)
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.55), value: clamped)
        }
        .frame(height: height)
        .onAppear {
            guard flows else { return }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) {
                flowPhase = 2.4
            }
        }
    }
}

// MARK: - 环形进度（Juicy 的圆环瓦片）

struct RingGauge: View {
    /// 0...1
    let fraction: Double
    var tint: Color = JB.green
    var size: CGFloat = 52
    var lineWidth: CGFloat = 5
    var symbol: String?
    var caption: String?

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(JB.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: clamped)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.28, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)

            if let caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(JB.label)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 迷你曲线

/// 功率历史。Juicy 的 KPI 瓦片里都有这么一条 sparkline，
/// 它让「现在这个数」有了上下文。
struct Sparkline: View {
    let values: [Double]
    var tint: Color = JB.green
    var height: CGFloat = 22

    private var path: (line: Path, area: Path) {
        var line = Path()
        var area = Path()
        guard values.count >= 2 else { return (line, area) }

        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 0.01)
        let stepX = 1.0 / CGFloat(values.count - 1)

        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            // 留 12% 上下边距，避免曲线贴边
            let norm = CGFloat((v - lo) / span)
            let y = 1 - (0.12 + norm * 0.76)
            let p = CGPoint(x: x, y: y)
            if i == 0 {
                line.move(to: p)
                area.move(to: CGPoint(x: x, y: 1))
                area.addLine(to: p)
            } else {
                line.addLine(to: p)
                area.addLine(to: p)
            }
        }
        area.addLine(to: CGPoint(x: 1, y: 1))
        area.closeSubpath()
        return (line, area)
    }

    var body: some View {
        GeometryReader { geo in
            let p = path
            ZStack {
                p.area
                    .applying(CGAffineTransform(scaleX: geo.size.width, y: geo.size.height))
                    .fill(
                        LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                p.line
                    .applying(CGAffineTransform(scaleX: geo.size.width, y: geo.size.height))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 洞察卡（Juicy 的琥珀描边提示）

struct InsightCard: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = JB.orange

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JB.value)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(JB.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(alignment: .leading) {
            // Juicy 用的是一条左侧强调边，而不是整块填充
            RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                .fill(tint)
                .frame(width: 2.5)
                .padding(.vertical, 7)
                .padding(.leading, 1.5)
        }
    }
}

// MARK: - 应用图标

/// 直接从 bundle 取真实应用图标 —— 这一步最能去掉「一堆文字」的观感。
/// 没有自带图标的 bundle（很多命令行/自组装工具）会取到一张空白方块，
/// 那种情况下退成一个中性字形，别让排行里出现一块「什么都没有」。
struct AppIconBadge: View {
    let bundlePath: String
    var size: CGFloat = 18

    private var realIcon: NSImage? {
        let resources = bundlePath + "/Contents/Resources"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: resources),
              files.contains(where: { $0.hasSuffix(".icns") }) else { return nil }
        return NSWorkspace.shared.icon(forFile: bundlePath)
    }

    var body: some View {
        Group {
            if let realIcon {
                Image(nsImage: realIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(JB.track)
                    .overlay(
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: size * 0.56))
                            .foregroundStyle(JB.label)
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 英雄数字

/// Juicy 的主视觉：一个很大的数字 + 小号单位。
/// 数值变化时走 contentTransition，数字是「滚」过去的，不是硬切。
struct HeroNumber: View {
    let value: Int
    let unit: String
    var tint: Color = JB.green
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .foregroundStyle(tint)
            Text(unit)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint.opacity(0.6))
        }
        .animation(.smooth(duration: 0.5), value: value)
    }
}

// MARK: - 键值条目

struct KeyValue: View {
    let label: String
    let value: String
    var tint: Color = JB.value
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(JB.label)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(JB.label)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

// MARK: - 分区标题

struct SectionLabel: View {
    let text: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JB.label)
            }
            MicroLabel(text: text)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5))
                    .foregroundStyle(JB.faint)
            }
        }
    }
}
