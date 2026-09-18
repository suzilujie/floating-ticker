import Foundation

/// 行情快照：一次价格推送的完整状态。
/// 渲染层只依赖本结构，不关心数据来自哪个交易所。
struct TickerSnapshot: Equatable {
    /// 交易对标识，例如 BTCUSDT
    let symbol: String
    /// 展示名称，例如 "BTC / USDT  现货"
    let displayName: String
    /// 最新价
    let last: Double
    /// 24 小时涨跌幅（百分数值，如 0.71 表示 +0.71%）
    let changePercent: Double
    /// 数据时间
    let updatedAt: Date

    /// 是否为上涨（用于涨跌配色）
    var isUp: Bool { changePercent >= 0 }
}
