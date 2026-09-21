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

    /// 数据源切换通知（携带新源名）。
    ///
    /// 为什么需要：不同交易所有基差（basis，实测 CoinEx 77879 / Gate 77935 /
    /// OKX 77947，约 0.09%），切换源时价格会瞬间跳变。报警用的是「穿越判定」
    /// （比较上一价与当前价），若不把这次跳变摘出去，就可能凭空触发一次误报。
    /// 方向说明：用回调而非直接调用 AlertEngine，保持依赖单向（Alert → Market）。
    var onSourceChanged: ((String) -> Void)?

    private var sources: [MarketDataSource] = []
    private var currentIndex = 0
    private var currentSource: MarketDataSource?
    private var stallTimer: Timer?

    /// 探测代次：start/stop 时自增，用于丢弃过期（在途）的探测回调 ——
    /// 否则源链重建后，迟到的探测结果会把已停用的一组源又启起来。
    private var probeGeneration = 0

    private init() {}

    // MARK: - 对外接口

    func start() {
        stop()
        probeGeneration += 1

        // 启动即用 Gate 链：首帧行情秒级到达，不被 OKX 探测的等待拖住。
        // 探测判定 OKX 可达后，再把它升级为链首（见 probeOKXAvailability）。
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
        probeOKXAvailability(generation: probeGeneration)
    }

    func stop() {
        probeGeneration += 1   // 作废在途探测，避免迟到回调重启源链
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
        LogCollector.shared.append(
            "market: 启用 \(source.name)（层级 \(source.tier)，链上第 \(currentIndex + 1)/\(sources.count)）"
        )
        // 先通知下游清理与「源」绑定的状态（报警引擎据此摘掉跨源跳变），再启动新源
        onSourceChanged?(source.name)
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

    // MARK: - 首选源探测（自适应优先级）

    /// 探测 OKX 可达性；可达则把它升级为首选源。
    ///
    /// 背景：OKX 直连不可达（`ws.okx.com` 被 TLS 阻断、`www.okx.com` 遭 DNS 污染），
    /// 仅在挂代理的网络下可用。这里刻意**不检测「是否开了 VPN」**——iOS 上测不准
    /// （TUN 模式 VPN 不写系统代理键、跨 App 读不到 VPN 状态、系统自带隧道会误判），
    /// 而是直接验证端点此刻是否可达，依据是事实而非推断（详见 SourceProbe 注释）。
    private func probeOKXAvailability(generation: Int) {
        SourceProbe.probeOKX { [weak self] isReachable in
            guard let self = self else { return }   // 回调已在主线程
            guard self.probeGeneration == generation else {
                LogCollector.shared.append("probe: 结果已过期，忽略（源链已重建）")
                return
            }
            guard isReachable else { return }
            self.promoteOKXToPrimary()
        }
    }

    /// 把 OKX 插到源链首并立即切过去。
    ///
    /// 原 Gate 链**整体保留**在后：OKX 之后依次是 Gate WS → Gate REST → CoinEx，
    /// 即「能用欧易就用欧易，欧易挂了立刻回 Gate」，而不是直接掉到异构兜底。
    private func promoteOKXToPrimary() {
        guard !sources.contains(where: { $0 is OKXFuturesWebSocketSource }) else { return }
        sources.insert(OKXFuturesWebSocketSource(), at: 0)
        LogCollector.shared.append("market: OKX 可达 → 优先使用 OKX 永续 WS（Gate 链保留为兜底）")

        currentSource?.stop()
        currentIndex = 0
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
