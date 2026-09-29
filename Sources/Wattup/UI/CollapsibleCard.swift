import SwiftUI

/// 可折叠的数据分区。
///
/// 弹窗里的「功率流向 / 电池 / 充电器 / 能耗排行」都套这一层：
/// 折叠后只留一行「图标 + 微标签 + 右侧摘要」，用户想看的细项才展开。
/// 展开状态按 id 存 UserDefaults，跨启动保持（不进程内记忆，因为弹窗是反复重建的）。
///
/// 摘要必须写**当下最有信息量的那个数**，否则折叠了就只剩一个标题，
/// 用户还得点开才知道发生了什么。
struct CollapsibleCard<Content: View>: View {

    let id: String
    let title: String
    let symbol: String
    var summary: String?
    var summaryTint: Color = JB.value
    var defaultExpanded: Bool = true
    /// 展开/折叠后通知外层重新量高度
    var onToggle: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var expanded: Bool

    init(id: String,
         title: String,
         symbol: String,
         summary: String? = nil,
         summaryTint: Color = JB.value,
         defaultExpanded: Bool = true,
         onToggle: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.summaryTint = summaryTint
        self.defaultExpanded = defaultExpanded
        self.onToggle = onToggle
        self.content = content()
        // 首次运行没有记忆值，用 defaultExpanded；之后完全听用户的
        let stored = UserDefaults.standard.object(forKey: Self.storageKey(id)) as? Bool
        _expanded = State(initialValue: stored ?? defaultExpanded)
    }

    private static func storageKey(_ id: String) -> String { "section.\(id).expanded" }

    var body: some View {
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                header
                if expanded {
                    content
                        .padding(.horizontal, 12)
                        .padding(.bottom, 11)
                        .transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.smooth(duration: 0.26)) { expanded.toggle() }
            UserDefaults.standard.set(expanded, forKey: Self.storageKey(id))
            onToggle?()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JB.label)
                    .frame(width: 13)

                MicroLabel(text: title)

                Spacer(minLength: 6)

                if let summary {
                    Text(summary)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(summaryTint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(JB.faint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, expanded ? 10 : 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "折叠此分区" : "展开此分区")
    }
}
