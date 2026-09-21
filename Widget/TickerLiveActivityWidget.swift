import ActivityKit
import SwiftUI
import WidgetKit

/// Widget Extension 入口。
///
/// 为什么需要单独一个 target：**实时活动的 UI 必须定义在 Widget Extension 里**
/// （系统要求，`ActivityConfiguration` 只能在 widget extension 中使用）。
/// 主 App 只能通过 ActivityKit 请求 / 更新内容，不能自己画实时活动。
@main
struct FloatingTickerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TickerLiveActivityWidget()
    }
}

/// 行情实时活动：锁屏卡片 + 灵动岛（紧凑 / 展开 / 最小三种形态）
struct TickerLiveActivityWidget: Widget {

    /// 品牌色（与主 App 的悬浮窗一致）
    private static let accent = Color(red: 0.98, green: 0.65, blue: 0.18)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TickerActivityAttributes.self) { context in

            // MARK: 锁屏 / 通知中心上的卡片
            LockScreenCard(context: context)
                .activityBackgroundTint(Color(white: 0.07))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in

            DynamicIsland {
                // MARK: 展开态
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(Self.changeText(context.state.changePercent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Self.changeColor(context.state.changePercent))
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(Self.priceText(context.state.price))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                }

            } compactLeading: {
                // MARK: 紧凑态（左）：币种标识
                Text("₿")
                    .font(.caption.bold())
                    .foregroundStyle(Self.accent)

            } compactTrailing: {
                // MARK: 紧凑态（右）：整数价格
                Text(Self.shortPriceText(context.state.price))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)

            } minimal: {
                // MARK: 最小态（多个实时活动并存时）
                Text("₿")
                    .font(.caption.bold())
                    .foregroundStyle(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }

    // MARK: - 文案与配色
    //
    // 注意：Widget Extension 是**独立进程**，拿不到主 App 里的工具方法
    // （如 TickerFrameRenderer 的格式化），所以这里自带一份。

    static func priceText(_ price: Double) -> String {
        price > 0 ? String(format: "%.1f", price) : "--"
    }

    /// 灵动岛紧凑态空间很窄，用整数避免被截断
    static func shortPriceText(_ price: Double) -> String {
        price > 0 ? String(format: "%.0f", price) : "--"
    }

    static func changeText(_ change: Double) -> String {
        String(format: "%+.2f%%", change)
    }

    static func changeColor(_ change: Double) -> Color {
        change >= 0
            ? Color(red: 0.29, green: 0.85, blue: 0.5)      // 绿涨
            : Color(red: 0.97, green: 0.44, blue: 0.44)     // 红跌
    }
}

/// 锁屏卡片：左侧币对与价格，右侧涨跌幅与更新时间
private struct LockScreenCard: View {

    let context: ActivityViewContext<TickerActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TickerLiveActivityWidget.priceText(context.state.price))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(TickerLiveActivityWidget.changeText(context.state.changePercent))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(TickerLiveActivityWidget.changeColor(context.state.changePercent))
                Text(context.state.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
