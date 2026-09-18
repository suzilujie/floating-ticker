import Combine
import Foundation

/// 行情状态聚合：持有最新快照、当前数据源与连接状态，
/// 并在主源失败时按层级降级（L1 → L2）。
///
/// M2 阶段只做"能用 + 可观测"；完整的健康检查、回切与异构兜底（L3）
/// 按设计文档 4.3 节在 M4 实现。
final class TickerStore: ObservableObject {

    static let shared = TickerStore()

    @Published private(set) var snapshot: TickerSnapshot?
    @Published private(set) var activeSourceName = "未启动"
    @Published private(set) var state: MarketState = .idle
    @Published private(set) var tickCount = 0
    @Published private(set) var lastTickAt: Date?

    /// 每笔行情推送后的回调（报警引擎等下游模块使用）。
    ///
    /// 说明：刻意用显式回调而非让外部订阅 `$snapshot`——`snapshot` 是
    /// `private(set)`，其投影值跨文件访问存在版本差异风险；回调更直白也更好测。
    var onSnapshot: ((TickerSnapshot) -> Void)?

    private var sources: [MarketDataSource] = []
    private var currentIndex = 0
    private var currentSource: MarketDataSource?
    private var stallTimer: Timer?

    private init() {}

    // MARK: - 对外接口

    func start() {
        stop()
        // 永续行情源分层：L1 实时 WS（直连）→ L2 同域 REST → L3 异构 REST
        sources = [
            GateFuturesWebSocketSource(),
            GateFuturesRestSource(),
            CoinExFuturesRestSource()
        ]
        currentIndex = 0
        tickCount = 0
        activateCurrentSource()
        startStallWatchdog()
    }

    func stop() {
        currentSource?.stop()
        currentSource = nil
        sources = []
        stallTimer?.invalidate()
        stallTimer = nil
        state = .idle
        activeSourceName = "未启动"
        LogCollector.shared.append("market: 已全部停止")
    }

    // MARK: - 数据源切换

    private func activateCurrentSource() {
        guard currentIndex < sources.count else {
            LogCollector.shared.append("market: 无可用数据源")
            state = .failed("无可用数据源")
            return
        }

        let source = sources[currentIndex]
        currentSource = source

        source.onTick = { [weak self] snapshot in
            guard let self = self else { return }
            self.snapshot = snapshot
            self.tickCount += 1
            self.lastTickAt = snapshot.updatedAt
            self.onSnapshot?(snapshot)
        }

        source.onState = { [weak self] newState in
            guard let self = self else { return }
            // 只接受当前源的状态，避免已停用源的迟到回调干扰
            guard self.currentSource === source else { return }
            self.state = newState
            if case .failed = newState {
                self.escalateToNextTier()
            }
        }

        activeSourceName = source.name
        LogCollector.shared.append("market: 启用 \(source.name)（层级 \(source.tier)）")
        source.start()
    }

    private func escalateToNextTier() {
        guard currentIndex + 1 < sources.count else {
            LogCollector.shared.append("market: 已无更低层级可降级")
            return
        }
        currentSource?.stop()
        currentIndex += 1
        LogCollector.shared.append("market: 降级到层级 \(sources[currentIndex].tier)")
        activateCurrentSource()
    }

    // MARK: - 心跳看门狗（M4 扩充为完整健康检查）

    private func startStallWatchdog() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let last = self.lastTickAt else { return }
            let gap = Date().timeIntervalSince(last)
            if gap > 5 {
                LogCollector.shared.append("market: \(Int(gap)) 秒无推送（疑似中断）")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }
}
