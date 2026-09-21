import ActivityKit
import Foundation

/// 实时活动（Live Activity）的数据模型 —— **主 App 与 Widget Extension 共享**。
///
/// 这两个部分是**独立的两个进程 / 两个 bundle**，靠这份 `Codable` 结构传递状态：
/// - 主 App 负责 `Activity.request` / `update`（写入状态）
/// - Widget Extension 负责渲染（读取状态）
///
/// 因此本文件在**两个 target 的 sources 里都被包含**（见 `project.yml`）。
/// 改动它时注意：两端都要能编译。
struct TickerActivityAttributes: ActivityAttributes {

    /// 随时间变化的内容（每次 `update` 写入）
    struct ContentState: Codable, Hashable {
        /// 最新价
        var price: Double
        /// 24h 涨跌幅（百分比，如 -1.23 表示 -1.23%）
        var changePercent: Double
        /// 该价格的时间
        var updatedAt: Date
    }

    /// 固定不变的内容
    var symbol: String
}
