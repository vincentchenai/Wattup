import Foundation

/// 系统充电策略的**只读**读取。
///
/// ## 数据源与权限
///
/// `/Library/Preferences/com.apple.powerd.charging.plist` —— 由 powerd 维护，
/// **root 可写但全局可读**（实测 `-rw-r--r-- root:wheel`）。也就是说
/// **读取这个策略完全不需要提权**，只有改写才需要。
///
/// 顶层 `policies` 的值是一段 `NSKeyedArchiver` 归档（`Data`），不是普通 plist 字典。
///
/// ## 归档结构（实测 macOS 26.6.2 / Apple M5）
///
/// ```text
/// $objects = [
///   "$null",
///   { "$class": UID(7), "NS.objects": [UID(2)] },
///   { "$class": UID(6),                    // ← ChargeCtrlPolicy
///     "reason": UID(3),                    //   对象引用 → $objects[3]
///     "soclimit": 80,                      //   内联标量
///     "drain": True, "noChargeToFull": False,
///     "isEndOfCharge": False, "terminated": False,
///     "owner": 32214, "token": UID(4) },
///   "optimizedBatteryCharging",            // ← $objects[3]
///   …
/// ]
/// ```
///
/// ## 为什么标量和 `reason` 走两条不同的路
///
/// 实测 `NSKeyedUnarchiver` 的 keyed 容器**只解析 UID 形式的值**：
/// `reason` 是 UID 所以能解出来，而 `soclimit` / `drain` / `owner` 这些
/// **内联写在对象字典里的标量**一律返回 `nil` / `0` / `false` ——
/// 尽管 `containsValue(forKey:)` 报 `true`。所以：
///
/// - **标量**：用 `PropertyListSerialization` 展开 `$objects` 直接读（与 Python
///   `plistlib` 读到的值逐项一致）；
/// - **`reason`**：它是 UID，用 `NSKeyedUnarchiver` + 一个只解 `reason` 的 shim 取。
///
/// 两条路读的是同一段 blob、同一个对象，不会产生前后不一致的快照。
///
/// ## 语义边界（界面必须守住）
///
/// 这个文件描述的是**系统被配置成要做什么**，不是**此刻正在做什么**。
/// 优化充电存在与否、是否正在保持在某个电量，是两个独立事实 ——
/// 所以 `ChargingPolicy` 只承载配置，`isHoldingNow(_:_:)` 才结合实时电量回答"此刻"。
/// 把"读不到"渲染成"没有开启优化充电"同样是撒谎，见 `ChargingPolicyDisplay`。
struct ChargingPolicy: Equatable, Sendable {

    /// `reason` 的原始值，如 `optimizedBatteryCharging`。
    ///
    /// 刻意保留原始字符串而不映射成枚举：未知取值（例如手动充电上限所用的 reason）
    /// 原样带出来展示，宁可让用户看到一个英文标识，也不猜错它的含义。
    var reason: String?

    /// 停止充电 / 维持电量所在的百分比（本机为 80）。
    var socLimit: Int?

    /// 归档里的其余字段。当前界面不展示，留给 `--dump` 与自检做取证，
    /// 免得日后要排查时才发现当初没读。
    var drain = false
    var noChargeToFull = false
    var isEndOfCharge = false
    var terminated = false
    /// 策略的属主进程号。含义未经证实，**不展示**，只随 `--dump` 带出来。
    var ownerPID: Int?

    /// 本次读数的采集时间。策略很少变，界面上要标出这是什么时候读的。
    var readAt = Date()

    /// 系统"优化电池充电"所用的 reason 取值（实测）。
    static let optimizedReason = "optimizedBatteryCharging"

    var isOptimizedCharging: Bool { reason == Self.optimizedReason }

    /// **真正在生效**的停充点。
    ///
    /// 策略被标记结束后，记录里的 `socLimit` 仍然留着（实测 terminated 与 soclimit 会同时存在），
    /// 但它不再生效 —— 界面和判定都必须读这个属性，不要直接读 `socLimit`，
    /// 否则会把一条已废弃的记录显示成"正在生效的上限"。
    var effectiveSocLimit: Int? { terminated ? nil : socLimit }
}

// MARK: - 读取

enum ChargingPolicyReader {

    static let policyPath = "/Library/Preferences/com.apple.powerd.charging.plist"

    /// 读一次系统充电策略。
    ///
    /// 返回 `nil` 明确表示**不知道**（文件缺失 / 不是预期的归档结构），
    /// 不表示"没有策略"。界面必须把这两种情况说成不同的话。
    ///
    /// 实测一次约 0.3 ms（读 700 字节文件 + 两次 plist 展开 + 一次 unarchive），
    /// 所以它能进轮询，但仍然按事件驱动调用，见 `PowerModel` 里的节流说明。
    static func read() -> ChargingPolicy? {
        guard let data = FileManager.default.contents(atPath: policyPath) else { return nil }
        return parseContainer(data)
    }

    /// 从**整个 plist 文件**的内容里取出策略。拆出来是为了让自检能喂合成数据。
    static func parseContainer(_ data: Data) -> ChargingPolicy? {
        guard let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = top as? [String: Any],
              let blob = dict["policies"] as? Data
        else { return nil }
        return parseArchive(blob)
    }

    /// 从 `policies` 归档里取出策略对象。
    static func parseArchive(_ blob: Data) -> ChargingPolicy? {
        guard let root = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
              let dict = root as? [String: Any],
              let objects = dict["$objects"] as? [Any],
              let policy = policyDictionary(in: objects)
        else { return nil }

        var p = ChargingPolicy()
        p.socLimit = number(policy["soclimit"])?.intValue
        p.drain = number(policy["drain"])?.boolValue ?? false
        p.noChargeToFull = number(policy["noChargeToFull"])?.boolValue ?? false
        p.isEndOfCharge = number(policy["isEndOfCharge"])?.boolValue ?? false
        p.terminated = number(policy["terminated"])?.boolValue ?? false
        p.ownerPID = number(policy["owner"])?.intValue
        p.reason = decodeReason(blob)
        p.readAt = Date()
        return p
    }

    /// 在 `$objects` 里找策略对象。
    ///
    /// 判据是「带 `soclimit` 的字典」而不是固定下标 —— `$objects` 的顺序由归档器
    /// 决定，不是可以依赖的契约。`soclimit` 是 `ChargeCtrlPolicy` 独有的字段。
    private static func policyDictionary(in objects: [Any]) -> [String: Any]? {
        let dicts = objects.compactMap { $0 as? [String: Any] }
        if let hit = dicts.first(where: { $0["soclimit"] != nil }) { return hit }
        // 退化判据：至少要有 reason，才敢当成策略对象
        return dicts.first(where: { $0["reason"] != nil && $0["noChargeToFull"] != nil })
    }

    /// 内联标量在这里已经是 `NSNumber` / `String`，直接取。
    private static func number(_ any: Any?) -> NSNumber? {
        if let n = any as? NSNumber { return n }
        if let i = any as? Int { return NSNumber(value: i) }
        if let b = any as? Bool { return NSNumber(value: b) }
        return nil
    }

    /// 只解 `reason` 的 shim。
    ///
    /// `reason` 的值是 UID 引用，只有 `NSKeyedUnarchiver` 会去解析它 ——
    /// 这正是它唯一能帮上忙的地方，其余字段交给上面的标量路径。
    ///
    /// `@objc(...)` 是必须的：`NSCoding` 要求类名在归档里稳定，
    /// 而 Swift 会给嵌套类生成带模块名的重整名 —— 不显式指定就编译不过。
    @objc(WattupChargingReasonShim)
    private final class ReasonShim: NSObject, NSCoding {
        var reason: String?
        required init?(coder: NSCoder) {
            reason = coder.decodeObject(forKey: "reason") as? String
        }
        func encode(with coder: NSCoder) {}
    }

    private static func decodeReason(_ blob: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ReasonShim.self, forClassName: "ChargeCtrlPolicy")
        defer { unarchiver.finishDecoding() }
        guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [Any] else {
            return nil
        }
        for item in root {
            if let shim = item as? ReasonShim, let reason = shim.reason { return reason }
        }
        return nil
    }
}

// MARK: - 此刻是否被"按住"

/// 判断一条策略**此刻**是否正在生效所必需的实时电量信息。
///
/// 单独抽出来是为了让映射逻辑成为纯函数 —— 不必起真机、不必改电压就能把
/// 全部分支自检一遍（见 `--selfcheck-charging-policy`）。
struct ChargingHoldContext: Equatable, Sendable {
    var isExternalConnected: Bool
    var isCharging: Bool
    var percentage: Int
}

extension ChargingPolicy {
    /// 是否**此刻**正被这条策略按在这个电量上。
    ///
    /// 判据是三个事实同时成立：接着电源、没有在充电、电量已经到达（或超过）策略设定的位置。
    /// 只满足前两个还不够 —— 那也可能是"已充满"。只看 `reason` 更不够：
    /// 这个文件说的是配置，插着电时它可能正在往 100% 充。
    func isHoldingNow(_ live: ChargingHoldContext) -> Bool {
        guard let limit = effectiveSocLimit else { return false }
        return live.isExternalConnected && !live.isCharging && live.percentage >= limit
    }
}

// MARK: - 界面文案（纯函数）

/// 把策略映射成界面文案。
///
/// 刻意做成**纯函数**：输入决定输出，没有隐藏状态，所以合成几组输入就能把
/// 每个分支都断言一遍。界面里那些"看着对但其实没跑到"的分支，都是靠这个抓出来的。
enum ChargingPolicyDisplay {

    enum Tone: String, Equatable, Sendable {
        /// 策略存在且此刻正在按住电量
        case holding
        /// 策略存在但此刻没在按住（没插电 / 正在充 / 已充满）
        case idle
        /// 读不到 —— 不知道，不是"没有"
        case unknown
    }

    struct Text: Equatable, Sendable {
        var title: String
        var detail: String
        var badge: String
        var tone: Tone
    }

    static func text(for policy: ChargingPolicy?, live: ChargingHoldContext) -> Text {
        guard let policy else { return unreadable }

        // 「读不到停充点」有两种成因，**都不能硬编一个数值出来**，
        // 但也**不能一律说成"读不到"** —— 策略已被系统标记结束，和文件读不出来，
        // 是两件完全不同的事，用户据此采取的动作也不同。
        guard let limit = policy.effectiveSocLimit else {
            return Text(
                title: "当前没有生效的充电策略",
                detail: "系统里这条策略记录"
                    + (policy.terminated ? "已标记为结束" : "没有给出停充电量")
                    + "。本应用没看到任何生效的充电限制；如果插电时仍然停在某个电量，"
                    + "说明那个限制来自这里读不到的地方。",
                badge: "未启用",
                tone: .idle)
        }

        let holding = policy.isHoldingNow(live)
        let tone: Tone = holding ? .holding : .idle

        if policy.isOptimizedCharging {
            return Text(
                title: "优化电池充电",
                detail: "macOS 学习你的使用节律，先充到 \(limit)% 停住，"
                    + "在你真正要用之前再充满。偶尔充到 100% 是校准，不是失控。",
                badge: holding ? "正在保持在 \(limit)%" : idleBadge(live),
                tone: tone)
        }

        // 未收录的 reason：把它原样带出来，让用户/维护者能对着系统资料查
        let raw = policy.reason ?? "（未提供）"
        return Text(
            title: "系统充电策略生效中",
            detail: "停止充电电量 \(limit)%，策略标识 \(raw)。"
                + "这个标识不在本应用已收录的取值里，因此不做解释。",
            badge: holding ? "正在保持在 \(limit)%" : idleBadge(live),
            tone: tone)
    }

    /// 读不到时的说法。单独抽出来，免得两处各写一套而慢慢跑偏。
    static let unreadable = Text(
        title: "未能读取系统充电策略",
        detail: "没有读到 \(ChargingPolicyReader.policyPath)，或它的结构与预期不同。"
            + "这只代表本应用读不到，不代表系统没有在优化充电。",
        badge: "读不到",
        tone: .unknown)

    private static func idleBadge(_ live: ChargingHoldContext) -> String {
        if !live.isExternalConnected { return "未接电源" }
        if live.isCharging { return "正在充电" }
        return "未在保持"
    }
}

// MARK: - 自检

/// `--selfcheck-charging-policy`：把这条读取链路从头到尾验一遍。
///
/// **刻意把"验了什么"和"没验什么"写在同一份输出里。** 这条链路的可信度完全取决于
/// 边界说清楚：能读到策略 ≠ 系统正在按它执行，而后者要靠真机观察（插电停在 80%）。
enum ChargingPolicyCheck {

    static func run(live: ChargingHoldContext) -> [String] {
        var out: [String] = []

        // ① 文件层面：只读不等于不需要权限，先把权限摆出来
        out.append("=== ① 数据源 ===")
        out.append("路径: \(ChargingPolicyReader.policyPath)")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ChargingPolicyReader.policyPath) {
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let owner = attrs[.ownerAccountName] as? String ?? "?"
            let group = attrs[.groupOwnerAccountName] as? String ?? "?"
            out.append(String(format: "大小: %d 字节   属主: %@:%@   权限: 0%o (%@)",
                              size, owner, group, perm, permDescription(perm)))
        } else {
            out.append("⚠️  读不到文件属性（文件不存在或不可访问）")
        }

        // ② 原始归档结构：把 $objects 里的策略字典原样打出来，方便和下面的解析值对账
        out.append("")
        out.append("=== ② 原始归档（$objects 里带 soclimit 的那个字典）===")
        if let data = FileManager.default.contents(atPath: ChargingPolicyReader.policyPath),
           let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let container = top as? [String: Any],
           let blob = container["policies"] as? Data,
           let inner = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
           let dict = inner as? [String: Any],
           let objects = dict["$objects"] as? [Any] {
            out.append("$objects 条目数: \(objects.count)")
            if let policyDict = objects.compactMap({ $0 as? [String: Any] }).first(where: { $0["soclimit"] != nil }) {
                for key in policyDict.keys.sorted() {
                    let value = policyDict[key]!
                    let rendered: String
                    if let n = value as? NSNumber {
                        rendered = "\(n)"
                    } else if let s = value as? String {
                        rendered = "\"\(s)\""
                    } else {
                        // CFKeyedArchiverUID 在这里是 __NSCFType，description 里带索引
                        rendered = "UID → \(String(describing: value))"
                    }
                    out.append("  \(key) = \(rendered)")
                }
            } else {
                out.append("⚠️  $objects 里没有带 soclimit 的字典 —— 结构可能变了")
            }
        } else {
            out.append("⚠️  归档展开失败")
        }

        // ③ 解析结果
        out.append("")
        out.append("=== ③ 解析结果 ===")
        let policy = ChargingPolicyReader.read()
        if let p = policy {
            out.append("reason        = \(p.reason ?? "nil")\(p.isOptimizedCharging ? "   （已收录：优化电池充电）" : "")")
            out.append("soclimit      = \(p.socLimit.map(String.init) ?? "nil")")
            out.append("drain         = \(p.drain)")
            out.append("noChargeToFull= \(p.noChargeToFull)")
            out.append("isEndOfCharge = \(p.isEndOfCharge)")
            out.append("terminated    = \(p.terminated)")
            out.append("owner(pid)    = \(p.ownerPID.map(String.init) ?? "nil")   （含义未经证实，界面不展示）")
        } else {
            out.append("❌ 读不到策略（返回 nil）。注意这与「系统没有开启优化充电」是两回事。")
        }

        // ④ 再读一次，确认解析不依赖任何进程内状态
        if let again = ChargingPolicyReader.read(), let first = policy {
            out.append("")
            out.append("=== ④ 重复读取一致性 ===")
            let same = again.reason == first.reason && again.socLimit == first.socLimit
                && again.drain == first.drain && again.terminated == first.terminated
            out.append(same ? "✅ 两次读取字段完全一致" : "❌ 两次读取不一致（解析带了隐藏状态）")
        }

        // ⑤ 文案映射：把每个分支都喂一遍，避免"看着写全了其实没跑到"
        out.append("")
        out.append("=== ⑤ 文案映射分支 ===")
        let cases: [(String, ChargingPolicy?, ChargingHoldContext)] = [
            ("优化充电 · 正被按住", optimized(limit: 80),
             ChargingHoldContext(isExternalConnected: true, isCharging: false, percentage: 80)),
            ("优化充电 · 正在充", optimized(limit: 80),
             ChargingHoldContext(isExternalConnected: true, isCharging: true, percentage: 62)),
            ("优化充电 · 未接电源", optimized(limit: 80),
             ChargingHoldContext(isExternalConnected: false, isCharging: false, percentage: 55)),
            ("未知 reason · 上限 85", unknownReason("someFutureReason", limit: 85),
             ChargingHoldContext(isExternalConnected: true, isCharging: false, percentage: 85)),
            ("策略已标记结束（记录里仍留着 soclimit）", terminatedPolicy(limit: 80),
             ChargingHoldContext(isExternalConnected: true, isCharging: false, percentage: 80)),
            ("策略没有停充点", noLimitPolicy(),
             ChargingHoldContext(isExternalConnected: true, isCharging: false, percentage: 80)),
            ("读不到", nil,
             ChargingHoldContext(isExternalConnected: true, isCharging: false, percentage: 80)),
        ]
        for (name, input, ctx) in cases {
            let t = ChargingPolicyDisplay.text(for: input, live: ctx)
            let held = input?.isHoldingNow(ctx) ?? false
            out.append("  ▸ \(name)")
            out.append("      标题: \(t.title)")
            out.append("      徽标: \(t.badge)   基调: \(t.tone.rawValue)   判定按住: \(held)")
        }

        // ⑥ 与实时行为对账 —— 只在具备观察条件时才有结论
        out.append("")
        out.append("=== ⑥ 与实时行为对账 ===")
        out.append("当前: 接电源=\(live.isExternalConnected)  正在充电=\(live.isCharging)  电量=\(live.percentage)%")
        if let p = policy, let limit = p.socLimit, p.isHoldingNow(live) {
            out.append("✅ 此刻确实被策略按住（接电 + 未充电 + 电量 \(live.percentage)% ≥ 停充点 \(limit)%）"
                       + " —— 与读到的策略一致")
        } else if !live.isExternalConnected {
            out.append("○ 当前没接电源，不具备「是否确实停在停充点」的观察条件（这不等于策略有问题）")
        } else if live.isCharging {
            out.append("○ 当前正在充电，不具备「停住」的观察条件")
        } else if let p = policy, let limit = p.socLimit {
            out.append("○ 接电且未充电，但电量 \(live.percentage)% < 停充点 \(limit)% —— 可能刚拔插或已充满，不据此下结论")
        } else {
            out.append("○ 没有可用的策略，无法对账")
        }

        // ⑦ 读取成本
        out.append("")
        out.append("=== ⑦ 读取成本 ===")
        out.append(String(format: "单次读取: %.3f ms（20 次平均，含读文件 + 两次 plist 展开 + unarchive）",
                          measureReadCost()))
        out.append("按每分钟一次的节律 = 每小时约 "
                   + String(format: "%.1f ms", measureReadCost() * 60) + " CPU")

        out.append("")
        out.append("=== 本次自检【没有】验证的事 ===")
        out.append("· 系统是否真的在按这条策略执行（要真机观察：插上电是否停在 \(policy?.socLimit.map { "\($0)%" } ?? "停充点")）")
        out.append("· 手动「充电上限」所用的 reason 取值（本机未设置过，无法取得样本）")
        out.append("· `owner` 字段的确切含义")

        return out
    }

    // MARK: 造样本

    private static func optimized(limit: Int) -> ChargingPolicy {
        var p = ChargingPolicy()
        p.reason = ChargingPolicy.optimizedReason
        p.socLimit = limit
        p.drain = true
        return p
    }

    private static func unknownReason(_ reason: String, limit: Int) -> ChargingPolicy {
        var p = ChargingPolicy()
        p.reason = reason
        p.socLimit = limit
        return p
    }

    private static func terminatedPolicy(limit: Int) -> ChargingPolicy {
        var p = optimized(limit: limit)
        p.terminated = true
        return p
    }

    /// 有 reason、但记录里没有停充点 —— 不能凭 reason 猜一个数值出来
    private static func noLimitPolicy() -> ChargingPolicy {
        var p = ChargingPolicy()
        p.reason = ChargingPolicy.optimizedReason
        return p
    }

    private static func measureReadCost() -> Double {
        for _ in 0..<3 { _ = ChargingPolicyReader.read() }
        let iterations = 20
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = ChargingPolicyReader.read() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0 / Double(iterations)
    }

    private static func permDescription(_ perm: Int) -> String {
        let bits = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                    (0o040, "r"), (0o020, "w"), (0o010, "x"),
                    (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return bits.map { perm & $0 != 0 ? $1 : "-" }.joined()
    }
}

