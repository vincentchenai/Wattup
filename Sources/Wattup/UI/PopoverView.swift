import SwiftUI
import AppKit

// MARK: - 弹窗外壳（滚动容器）

/// 弹窗本体。高度由 AppDelegate 量好后写进 `model.popoverBodyHeight`：
/// 取「内容自然高度」与「程序坞之上的可用高度」的较小值，
/// 内容超了就滚动 —— 这样弹窗永远不会顶到程序坞。
struct PopoverView: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            PopoverContent(model: model)
        }
        .frame(width: 336, height: model.popoverBodyHeight)
        .background(JB.insetFill)
    }
}

// MARK: - 弹窗内容（自然高度，供测量与滚动共用）

struct PopoverContent: View {
    @ObservedObject var model: PowerModel

    private var flow: PowerFlowData { PowerFlowData(snapshot: model.snapshot) }

    var body: some View {
        let s = model.snapshot
        let flow = self.flow

        VStack(spacing: 9) {
            HeroCard(model: model)

            if let alert = InsightSection.alert(for: s, heldByPolicyAt: model.holdingChargeLimit) {
                InsightCard(symbol: alert.symbol, title: alert.title,
                            detail: alert.detail, tint: alert.tint)
            }

            KPIStrip(model: model)

            CollapsibleCard(id: "flow",
                            title: "功率流向",
                            symbol: "arrow.triangle.swap",
                            summary: Fmt.watts(flow.total, digits: 1),
                            onToggle: { model.bumpContentRevision() }) {
                PowerFlowBody(data: flow)
            }

            // 「电池」「充电器」「能耗排行」默认折叠。
            //
            // 原因不是省地方，而是**首屏高度必须稳定**：能耗排行的行数是数据决定的
            // （基线建立后 0～5 行都要能容纳），展开状态下自然高度会在 807～938 pt 之间漂，
            // 而程序坞之上的可用高度只有 829 pt —— 那就变成「开机看着好好的，
            // 过一会能耗基线建好了，弹窗自己开始滚动」。折叠后高度恒定 741 pt，
            // 无论数据怎么变，首屏都能完整显示到底部的退出按钮。
            CollapsibleCard(id: "health",
                            title: "电池",
                            symbol: "battery.100percent",
                            summary: healthSummary(s),
                            summaryTint: JB.greenText,
                            defaultExpanded: false,
                            onToggle: { model.bumpContentRevision() }) {
                HealthBody(snapshot: s)
            }

            CollapsibleCard(id: "adapter",
                            title: "充电器",
                            symbol: "powerplug.fill",
                            summary: adapterSummary(s),
                            summaryTint: adapterConnected(s) ? JB.greenText : JB.faint,
                            defaultExpanded: false,
                            onToggle: { model.bumpContentRevision() }) {
                AdapterBody(snapshot: s)
            }

            CollapsibleCard(id: "energy",
                            title: "能耗排行",
                            symbol: "flame.fill",
                            summary: energySummary,
                            summaryTint: JB.label,
                            defaultExpanded: false,
                            onToggle: { model.bumpContentRevision() }) {
                EnergyBody(energy: model.energy, snapshot: s)
            }

            FooterCard(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 336)
    }

    /// 折叠时也要能看出电池大概状况，所以摘要里放健康度 + 循环次数
    private func healthSummary(_ s: BatterySnapshot) -> String {
        var parts: [String] = []
        if let h = s.healthPercent { parts.append("健康 \(Fmt.percent(h))") }
        if let c = s.cycleCount { parts.append("循环 \(c)") }
        if parts.isEmpty { parts.append(s.healthCondition ?? s.batteryHealth ?? "—") }
        return parts.joined(separator: " · ")
    }

    /// 连接与否只看供电事实，不看有没有读到适配器名字（实测扩展坞常常读不到名字）
    private func adapterConnected(_ s: BatterySnapshot) -> Bool {
        s.isExternalConnected || (s.systemInputWatts ?? 0) > 0.05 || (s.adapterNegotiatedVoltageMV ?? 0) > 0
    }

    private func adapterSummary(_ s: BatterySnapshot) -> String {
        guard adapterConnected(s) else { return "未连接" }
        var parts = [Fmt.watts(s.systemInputWatts, digits: 1)]
        if let rated = s.adapterRatedWatts { parts.append("/ 额定 \(rated) W") }
        return parts.joined(separator: " ")
    }

    private var energySummary: String {
        let e = model.energy
        guard e.isBaselineReady else { return "建立基线中" }
        guard let top = e.apps.first else { return "本窗口无变化" }
        return "\(top.displayName) \(Fmt.milliWatts(top.milliWatts))"
    }
}

// MARK: - 英雄卡（Juicy 的主视觉）

private struct HeroCard: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        let s = model.snapshot
        let tint = s.heroTint
        let charging = s.isCharging

        CardBox(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HeroNumber(value: s.hasBattery ? s.percentage : 0,
                                   unit: "%", tint: tint)
                        StateChip(symbol: s.stateSymbol,
                                  text: s.statusText,
                                  tint: tint,
                                  pulses: charging)
                    }

                    Spacer(minLength: 0)

                    // Juicy 头部右上角的两组大写微标签
                    VStack(alignment: .trailing, spacing: 9) {
                        MicroStat(label: s.isCharging && !s.isFullyCharged ? "距充满" : "可使用",
                                  value: s.isCharging && !s.isFullyCharged
                                      ? Fmt.duration(s.timeToFullMinutes)
                                      : Fmt.duration(s.timeToEmptyMinutes))
                        MicroStat(label: "健康度",
                                  value: Fmt.percent(s.healthPercent),
                                  tint: JB.greenText)
                    }
                    .padding(.top, 3)
                }

                VStack(alignment: .leading, spacing: 5) {
                    JuicyBar(fraction: Double(s.hasBattery ? s.percentage : 0) / 100,
                             tint: tint,
                             height: 10,
                             flows: charging)
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 8.5))
                        Text("电量计每 60 秒刷新 · 采样于 \(Fmt.age(seconds: s.secondsSinceGaugeUpdate))")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(JB.faint)
                }

                if s.effectiveTelemetrySource.isDegraded {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                        Text("功率来源降级：\(s.effectiveTelemetrySource.label)")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(JB.orange)
                }
            }
        }
    }
}

private struct MicroStat: View {
    let label: String
    let value: String
    var tint: Color = JB.value

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            MicroLabel(text: label)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

// MARK: - 洞察（Juicy 的琥珀描边提示卡）

struct InsightSection {
    struct Alert {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
    }

    /// 至多返回一条。顺序即优先级：真问题在前，纯解释在后。
    ///
    /// 「接电但没在充」这一条直接回答用户最容易有的疑问 ——
    /// 它**只在确实被系统按住的时刻**出现（接着电源、没有在充电、电量已到策略位置），
    /// 不靠"读到了优化充电这个配置"就瞎报。
    static func alert(for s: BatterySnapshot, heldByPolicyAt limit: Int?) -> Alert? {
        if s.isNetDischargingWhilePlugged {
            let short = s.adapterHeadroomWatts.map { Fmt.watts(abs($0), digits: 1) } ?? "—"
            return Alert(
                symbol: "exclamationmark.triangle.fill",
                title: "适配器功率不够用",
                detail: "整机在满载运行，适配器顶不住，缺的 \(short) 由电池倒灌补上。电量会一边插着电一边下降。",
                tint: JB.orange)
        }
        if let limit {
            return Alert(
                symbol: "pause.circle.fill",
                title: "已接电源，但在 \(limit)% 停住了",
                detail: "这是系统「优化电池充电」在按着，不是没插好、也不是适配器不够。"
                    + "它会在你真正要用之前再充满；偶尔充到 100% 是校准。",
                tint: JB.orange)
        }
        if s.effectiveTelemetrySource == .derived {
            // 两种情况都会落到「推导口径」，**原因必须说清是哪一个** ——
            // 「没读到」和「读到了但与物理口径打架」对用户意味着完全不同的事。
            //
            // 但「打架」这一条要排除充电中：插电后遥测块（`PowerTelemetryData`，
            // 60 秒才刷新一次）还没跟上，那一拍的"打架"是暂时现象，
            // 拿它当故障提示会让人以为机器坏了。判据与「适配器功率不足」告警共用
            // 同一条原则：正在充电是正向状态，来源矛盾时不下结论（见设计文档 §15）。
            if s.batteryPowerIsCorroborated == false && !s.isCharging {
                let disc = s.identityDiscrepancyWatts.map { Fmt.watts($0, digits: 1) } ?? "—"
                let telemetrySays = (s.batteryNetWattsTelemetry ?? 0) < 0 ? "放电" : "充电"
                return Alert(
                    symbol: "exclamationmark.triangle.fill",
                    title: "功率遥测与电池读数不一致",
                    detail: "遥测说电池在\(telemetrySays)，电池端电压 × 电流却指向相反方向，"
                        + "两边差 \(disc)。这一轮以物理口径为准，功率来源已降级。",
                    tint: JB.orange)
            }
            return Alert(
                symbol: "info.circle.fill",
                title: "功率来自推导口径",
                detail: "没有读到 PowerTelemetryData，当前功率由电池端电压 × 电流推导，不含适配器侧数据。",
                tint: JB.orange)
        }
        return nil
    }

    /// 自检：洞察卡的**选卡结果**（`--selfcheck-power-caliber` 的第二段）。
    ///
    /// 这里是第三个会被染成橙色的界面（前两个是状态栏图标与顶部提示胶囊）。
    /// 用户看到「插上充电器却是橙色」时，这一处同样会中招 —— 所以一并钉住。
    /// 断言的是**标题**而不是颜色：选错卡比选对卡配错色更常见，也更容易悄悄回退。
    static func selfCheckColors() -> [String] {
        var lines: [String] = ["", "── 洞察卡（弹窗内，第三个橙色界面）──"]
        var allPassed = true

        func snap(charging: Bool = false, telemetryMW: Int?, voltageMV: Int? = nil,
                  amperageMA: Int? = nil, inputMW: Int? = nil,
                  holdingAtLimit: Bool = false, percentage: Int = 80) -> BatterySnapshot {
            var s = BatterySnapshot()
            s.hasBattery = true
            s.isExternalConnected = true
            s.percentage = percentage
            s.isCharging = charging
            s.batteryPowerMW = telemetryMW
            s.packVoltageMV = voltageMV
            s.packAmperageMA = amperageMA
            s.systemPowerInMW = inputMW
            s.isHoldingAtChargeLimit = holdingAtLimit
            s.telemetrySource = telemetryMW != nil ? .telemetry : .derived
            return s
        }

        struct Case {
            let name: String
            let snapshot: BatterySnapshot
            let limit: Int?
            /// 期望的标题；`nil` = 期望根本不出卡
            let expect: String?
        }

        let cases: [Case] = [
            Case(name: "插电 · 正在充电（遥测停在插电前那一拍）→ 不出「不一致」卡",
                 snapshot: snap(charging: true, telemetryMW: -7023, voltageMV: 12580,
                                amperageMA: 2100, inputMW: 0, percentage: 78),
                 limit: nil, expect: "功率来自推导口径"),

            Case(name: "插电 · 按上限保电 → 解释「为什么停住」",
                 snapshot: snap(telemetryMW: -7023, voltageMV: 12400, amperageMA: -566,
                                inputMW: 0, holdingAtLimit: true, percentage: 80),
                 limit: 80, expect: "已接电源，但在 80% 停住了"),

            Case(name: "接电未充电 · 真的欠功率 → 出「适配器功率不够用」",
                 snapshot: snap(telemetryMW: -3862, voltageMV: 12500, amperageMA: -308,
                                inputMW: 18312, percentage: 62),
                 limit: nil, expect: "适配器功率不够用"),

            Case(name: "接电未充电 · 遥测与物理口径打架 → 出「不一致」卡",
                 snapshot: snap(telemetryMW: -26498, voltageMV: 12710, amperageMA: 2683,
                                inputMW: 46379, percentage: 62),
                 limit: nil, expect: "功率遥测与电池读数不一致"),
        ]

        for c in cases {
            let got = alert(for: c.snapshot, heldByPolicyAt: c.limit)?.title
            let ok = got == c.expect
            allPassed = allPassed && ok
            lines.append("\(ok ? "✅" : "❌") \(c.name)")
            lines.append("     得到 \(got.map { "「\($0)」" } ?? "不出卡")"
                         + "｜期望 \(c.expect.map { "「\($0)」" } ?? "不出卡")")
        }
        lines.append(allPassed ? "✅ 洞察卡四条选卡分支全部符合预期" : "❌ 有分支不符合预期")
        return lines
    }
}

// MARK: - KPI 条（Juicy 的带曲线数字瓦片）

private struct KPIStrip: View {
    @ObservedObject var model: PowerModel

    private var spanText: String? {
        let m = model.historySpanMinutes
        return m >= 1 ? "近 \(m) 分" : nil
    }

    var body: some View {
        let s = model.snapshot
        HStack(spacing: 9) {
            KPITile(label: "整机消耗",
                    value: Fmt.watts(s.systemLoadWatts, digits: 1),
                    tint: JB.value,
                    values: model.loadHistory,
                    sparkTint: JB.green,
                    spanText: spanText)

            KPITile(label: s.isNetDischargingWhilePlugged ? "电池倒灌" : "电池净功率",
                    value: Fmt.watts(s.batteryNetWatts, digits: 2),
                    tint: (s.batteryNetWatts ?? 0) >= 0 ? JB.green : JB.orange,
                    values: model.batteryHistory,
                    sparkTint: (s.batteryNetWatts ?? 0) >= 0 ? JB.green : JB.orange,
                    spanText: spanText)
        }
    }
}

private struct KPITile: View {
    let label: String
    let value: String
    let tint: Color
    let values: [Double]
    let sparkTint: Color
    var spanText: String?

    var body: some View {
        CardBox(padding: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    MicroLabel(text: label)
                    Spacer(minLength: 2)
                    if let spanText {
                        Text(spanText)
                            .font(.system(size: 8.5))
                            .foregroundStyle(JB.faint)
                    }
                }
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if values.count >= 2 {
                    Sparkline(values: values, tint: sparkTint, height: 20)
                } else {
                    // 点数不够就诚实留白，不要画一条假的线
                    Text("积累中…")
                        .font(.system(size: 9))
                        .foregroundStyle(JB.faint)
                        .frame(height: 20, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - 功率流向

/// 流向的拆解结果。抽出来是为了让「折叠摘要」和「展开后的详图」用同一份口径，
/// 不会出现摘要一个数、详情另一个数。
struct PowerFlowData {
    struct Segment: Identifiable {
        let watts: Double
        let label: String
        let symbol: String
        let tint: Color
        var id: String { label }
    }

    let total: Double
    let segments: [Segment]
    let headline: String
    let symbol: String
    let caption: String

    init(snapshot s: BatterySnapshot) {
        let input = s.systemInputWatts ?? 0
        let load = s.systemLoadWatts ?? 0
        let battery = s.batteryNetWatts ?? 0

        if !s.isExternalConnected {
            let draw = max(abs(battery), load)
            let rem = s.timeToEmptyMinutes.map { "，剩余约 \(Fmt.duration($0))" } ?? ""
            total = draw
            segments = [Segment(watts: draw, label: "整机消耗", symbol: "laptopcomputer", tint: JB.green)]
            headline = "电池输出"
            symbol = "battery.75percent"
            caption = "电池以 \(Fmt.watts(draw)) 供电\(rem)"
            return
        }

        if battery >= 0 {
            total = max(input, load + battery)
            segments = [Segment(watts: load, label: "整机消耗", symbol: "laptopcomputer", tint: JB.neutral),
                        Segment(watts: battery, label: "充入电池", symbol: "bolt.fill", tint: JB.green)]
            headline = "适配器输出"
            symbol = "powerplug.fill"
            caption = "\(Fmt.watts(input)) = 整机 \(Fmt.watts(load)) + 电池 \(Fmt.watts(battery))"
            return
        }

        total = max(load, input + (-battery))
        segments = [Segment(watts: input, label: "适配器输入", symbol: "powerplug.fill", tint: JB.orange),
                    Segment(watts: -battery, label: "电池补充", symbol: "battery.25percent", tint: JB.red)]
        headline = "整机消耗"
        symbol = "laptopcomputer"
        caption = "适配器只给到 \(Fmt.watts(input))，不足的 \(Fmt.watts(-battery)) 由电池倒灌"
    }
}

private struct PowerFlowBody: View {
    let data: PowerFlowData

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: data.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JB.label)
                MicroLabel(text: data.headline)
                Spacer(minLength: 4)
                Text(Fmt.watts(data.total, digits: 1))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(JB.value)
            }

            // 分段条：每段一个 JuicyBar 的观感，段间留 2pt
            GeometryReader { geo in
                let total = max(data.total, 0.0001)
                let gapTotal = CGFloat(max(0, data.segments.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(data.segments) { seg in
                        Capsule(style: .continuous)
                            .fill(seg.tint)
                            .frame(width: max(3, (geo.size.width - gapTotal) * CGFloat(seg.watts / total)))
                    }
                    Spacer(minLength: 0)
                }
                .animation(.smooth(duration: 0.5), value: data.total)
            }
            .frame(height: 10)

            HStack(spacing: 12) {
                ForEach(data.segments) { seg in
                    HStack(spacing: 5) {
                        Image(systemName: seg.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(seg.tint)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            MicroLabel(text: seg.label)
                            Text(Fmt.watts(seg.watts, digits: 1))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(JB.value)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Text(data.caption)
                .font(.system(size: 9.5))
                .foregroundStyle(JB.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 电池健康（环形 + 明细）

private struct HealthBody: View {
    let snapshot: BatterySnapshot
    @State private var showAdvanced = false

    var body: some View {
        let s = snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                RingGauge(fraction: (s.healthPercent ?? 0) / 100,
                          tint: JB.green,
                          size: 58, lineWidth: 5.5,
                          symbol: "heart.fill",
                          caption: nil)

                VStack(spacing: 5) {
                    KeyValue(label: "循环次数", value: s.cycleCount.map { "\($0)" } ?? "—",
                             tint: JB.value, symbol: "arrow.triangle.2.circlepath")
                    KeyValue(label: "设计循环", value: s.designCycleCount.map { "\($0)" } ?? "—")
                    KeyValue(label: "满充容量", value: Fmt.capacity(s.maxCapacityMAH),
                             symbol: "battery.100percent")
                    KeyValue(label: "设计容量", value: Fmt.capacity(s.designCapacityMAH))
                }
                .frame(maxWidth: .infinity)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(spacing: 5) {
                    KeyValue(label: "标称容量", value: Fmt.capacity(s.nominalCapacityMAH))
                    if !s.cellVoltagesMV.isEmpty {
                        KeyValue(label: "电芯电压",
                                 value: s.cellVoltagesMV.map { String(format: "%.3f V", Double($0) / 1000) }
                                    .joined(separator: "  "))
                    }
                    if !s.weightRa.isEmpty {
                        KeyValue(label: "电芯内阻",
                                 value: s.weightRa.map(String.init).joined(separator: " / ") + " mΩ")
                    }
                    if let i = s.chargingCurrentMA, let v = s.chargingVoltageMV {
                        KeyValue(label: "充电目标", value: "\(Fmt.volts(v)) · \(Fmt.milliAmps(i))")
                    }
                    KeyValue(label: "主板侧输入",
                             value: (s.systemVoltageInMV ?? 0) > 0
                                 ? "\(Fmt.volts(s.systemVoltageInMV)) · \(Fmt.milliAmps(s.systemCurrentInMA))"
                                 : "—")
                    KeyValue(label: "适配器损耗",
                             value: Fmt.watts(s.adapterEfficiencyLossMW.map { Double($0) / 1000 }))
                    if (s.notChargingReason ?? 0) != 0 || (s.slowChargingReason ?? 0) != 0 {
                        KeyValue(label: "充电异常",
                                 value: "未充 \(s.notChargingReason ?? 0) · 慢充 \(s.slowChargingReason ?? 0)",
                                 tint: JB.orange)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("更多电芯与充电数据")
                        .font(.system(size: 10))
                }
                .foregroundStyle(JB.label)
            }
        }
    }
}

// MARK: - 充电器

private struct AdapterBody: View {
    let snapshot: BatterySnapshot

    /// 连接与否只能看供电事实，不能看有没有读到适配器名字 ——
    /// 实测有些扩展坞 / PD 源拿不到 `AdapterDetails.Name`，
    /// 那种情况下 `adapterName` 是 nil，但适配器其实正在 23 W 供电。
    private var isConnected: Bool {
        snapshot.isExternalConnected
            || (snapshot.systemInputWatts ?? 0) > 0.05
            || (snapshot.adapterNegotiatedVoltageMV ?? 0) > 0
    }

    var body: some View {
        let s = snapshot
        VStack(alignment: .leading, spacing: 8) {
            if isConnected {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(JB.greenSoft)
                        Image(systemName: "powerplug.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(JB.green)
                    }
                    .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.adapterName ?? "外接电源")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(JB.value)
                            .lineLimit(1)
                        Text(s.adapterManufacturer
                             ?? (s.adapterName == nil ? "未读到适配器名称" : ""))
                            .font(.system(size: 9))
                            .foregroundStyle(JB.faint)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        MicroLabel(text: "实际输入")
                        Text(Fmt.watts(s.systemInputWatts, digits: 1))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(JB.greenText)
                    }
                }

                if let v = s.adapterNegotiatedVoltageMV, let i = s.adapterNegotiatedCurrentMA {
                    KeyValue(label: "协商档位", value: "\(Fmt.volts(v)) · \(Fmt.milliAmps(i))")
                }
                if let rated = s.adapterRatedWatts {
                    KeyValue(label: "额定功率", value: "\(rated) W")
                }
                if !s.adapterPDOMenu.isEmpty {
                    Text("可用 " + s.adapterPDOMenu
                        .map { String(format: "%.0fV/%.1fA", Double($0.voltageMV) / 1000, Double($0.currentMA) / 1000) }
                        .joined(separator: "  "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(JB.faint)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "powerplug")
                        .font(.system(size: 10))
                        .foregroundStyle(JB.faint)
                    Text("未连接外接电源")
                        .font(.system(size: 11))
                        .foregroundStyle(JB.label)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - 应用能耗排行

private struct EnergyBody: View {
    let energy: EnergyScanResult
    let snapshot: BatterySnapshot

    private var maxMilliWatts: Double { max(energy.apps.first?.milliWatts ?? 1, 0.001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !energy.isBaselineReady {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在采集第二组样本以计算增量…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(JB.label)
                }
                .padding(.vertical, 5)
            } else if energy.apps.isEmpty {
                Text("本次窗口内所有进程的能耗计数均无变化")
                    .font(.system(size: 10.5))
                    .foregroundStyle(JB.label)
                    .padding(.vertical, 5)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(energy.apps.prefix(5).enumerated()), id: \.element.id) { idx, app in
                        EnergyRow(app: app, maxMilliWatts: maxMilliWatts, rank: idx)
                    }
                }
            }

            Text(coverageText)
                .font(.system(size: 9))
                .foregroundStyle(JB.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var coverageText: String {
        var text = "覆盖当前用户进程 \(energy.measuredProcessCount) 个，合计 \(Fmt.milliWatts(energy.measuredMilliWatts))"
        if let load = snapshot.systemLoadWatts, load > 0.1, energy.measuredMilliWatts > 0 {
            text += String(format: "，占整机 %.0f W 的 %.0f%%", load,
                           energy.measuredMilliWatts / 1000 / load * 100)
        }
        if energy.deniedProcessCount > 0 {
            text += "。另有 \(energy.deniedProcessCount) 个其他用户的进程无权读取"
        }
        text += "。仅覆盖 CPU 侧可归属能耗，用于相对比较。"
        return text
    }
}

private struct EnergyRow: View {
    let app: AppEnergy
    let maxMilliWatts: Double
    let rank: Int

    /// Juicy 的名次配色：第一名绿、第二名橙，其余中性 —— 避免整屏都在喊
    private var tint: Color {
        switch rank {
        case 0:  return JB.green
        case 1:  return JB.orange
        default: return JB.neutral
        }
    }

    private var ratio: Double {
        guard maxMilliWatts > 0 else { return 0 }
        return min(1, app.milliWatts / maxMilliWatts)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                AppIconBadge(bundlePath: app.bundlePath, size: 17)
                Text(app.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(JB.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Fmt.milliWatts(app.milliWatts))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(rank < 2 ? tint : JB.label)
            }
            JuicyBar(fraction: ratio, tint: tint, height: 4)
        }
    }
}

// MARK: - 底部（形态切换 / 开关 / 设置入口 / 退出）

private struct FooterCard: View {
    @ObservedObject var model: PowerModel

    private var lowPowerStateText: String {
        model.lowPowerMode ? "已开启" : "已关闭"
    }

    var body: some View {
        VStack(spacing: 9) {
            CardBox(padding: 11) {
                VStack(spacing: 9) {
                    ToggleRow(symbol: "leaf.fill",
                              title: "低电量模式",
                              stateText: lowPowerStateText,
                              tint: model.lowPowerMode ? JB.greenText : JB.label,
                              isOn: Binding(get: { model.lowPowerMode },
                                            set: { model.setLowPowerMode($0) }),
                              disabled: false)

                    if let hint = model.lowPowerModeHint {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 9))
                                .padding(.top, 0.5)
                            Text(hint)
                                .font(.system(size: 9.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(JB.orange)
                    }
                }
            }

            // 外观 / 提醒 / 阈值这些「设置一次就不常动」的项都收进应用内设置面板，
            // 这里只留一个入口 —— 弹窗本身是「看一眼」的地方，不该长成控制台。
            FooterButton(symbol: "gearshape.fill",
                         title: "设置…",
                         tint: JB.value,
                         fill: JB.insetFill) {
                SettingsWindowController.shared.show()
            }

            // Juicy 式的退出：整条大按钮，而不是角落里一个灰色小字
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                    Text("退出 Wattup")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(JB.value)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(JB.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(JB.cardStroke, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Text("采样 \(String(format: "%.2f", model.lastSampleDurationMS)) ms · 已刷新 \(model.refreshCount) 次")
                    .font(.system(size: 9))
                    .foregroundStyle(JB.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }
}

/// 弹窗底部的一枚动作按钮（与「退出」同版式，方便两条并排时对齐）
private struct FooterButton: View {
    let symbol: String
    let title: String
    var tint: Color = JB.value
    var fill: Color = JB.insetFill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JB.faint)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(JB.cardStroke, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    var stateText: String?
    var tint: Color = JB.label
    @Binding var isOn: Bool
    var disabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(JB.value)
            Spacer(minLength: 4)
            if let stateText {
                Text(stateText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(JB.faint)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // 系统默认开关的「开」是灰底圆点，一眼分不清开还是关；染成本应用的绿
                .tint(JB.green)
                .disabled(disabled)
        }
    }
}
