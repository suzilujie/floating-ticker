import Foundation

/// 行情源连接状态
enum MarketState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)

    var describe: String {
        switch self {
        case .idle:
            return "未启动"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case .failed(let reason):
            return "失败：" + reason
        }
    }
}

/// 行情源协议：所有数据源实现同一接口，上层只依赖协议（可插拔）。
/// 对应设计文档 4.4 节。
protocol MarketDataSource: AnyObject {
    /// 数据源名称（界面上显示）
    var name: String { get }
    /// 优先级层级，数值越小越优先（1 = 主源）
    var tier: Int { get }
    /// 收到推送
    var onTick: ((TickerSnapshot) -> Void)? { get set }
    /// 连接状态变化
    var onState: ((MarketState) -> Void)? { get set }

    func start()
    func stop()
}
