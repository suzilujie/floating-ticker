import Combine
import Foundation
import Network

/// 行情状态聚合：持有最新快照、当前数据源与连接状态。
///
/// **本版是一次结构性简化（真机结论驱动）：放弃 WebSocket，改为 REST 主动轮询。**
///
/// 为什么弃用 WS：
/// 真机上 WS 长连接非常不稳定 —— 锁屏 / 切网 / 息屏后屡屡进入「半死」状态
/// （TCP 还活着但不推数据，且**不报任何错**），每次都得靠停滞看门狗兜底，
/// 代价是十几秒的行情空档，而这段时间浮窗与灵动岛都在显示陈旧价格。
///
/// REST 的结构性优势：**每次请求都是独立的，没有"连接状态"可以半死**。
/// 失败就是明确的失败，下一个周期自然重试 —— 不需要连接级心跳、不需要"检测半死"、
/// 也不需要多级降级链。代价是延迟从"服务端推送级"变成"轮询周期级"。
///
/// 冗余方式：**同时向 OKX 与 Binance 各拉一次，先返回者胜**（见 `RacingFuturesRestSource`）。
/// 任一交易所变慢或不可达时，另一家无需任何切换逻辑就能顶上。
///
/// 自愈策略（本版刻意做减法，**不再有"失败触发"的重建循环**）：
///   1) **一轮失败就放弃这一轮** —— 什么都不做，等 2 秒后的下一轮。
///      轮询器本身就是自愈的，不需要任何外部干预；
///   2) **轮询器卡死兜底**：只在「长时间没有任何**轮次收尾**」
///      （≥ `pollerStallThreshold`）时才重建一次；
///   3) **回到前台**：同样只在轮询器疑似卡死时动手。
///
/// 网络恢复（NWPathMonitor）**不做任何动作**、只记一行日志 —— 下一轮 ≤2 秒自然恢复。
///
/// 线程约束：所有对外状态变更统一在主线程（数据源回调在此处归拢），
/// 故下游（界面、报警引擎）无需再处理线程问题。
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

    /// 每笔行情的**多播**通道。
    ///
    /// 为什么需要它：`onSnapshot` 是单播闭包（已被报警引擎占用），而实时活动
    /// 等附加消费者同样需要这份行情。用 Combine 的 Subject 做多播，
    /// 各消费者互不覆盖（谁想加就订阅，不用改这里）。
    let tickPublisher = PassthroughSubject<TickerSnapshot, Never>()

    /// 数据源切换通知（携带新源名）。
    ///
    /// 为什么需要：OKX 与 Binance 之间存在基差（同一时刻永续价差约 0.01%~0.09%），
    /// 轮到备源顶上时价格会跳变。报警用的是「穿越判定」（比较上一价与当前价），
    /// 若不把这次跳变摘出去，就可能凭空触发一次误报。
    /// 方向说明：用回调而非直接调用 AlertEngine，保持依赖单向（Alert → Market）。
    var onSourceChanged: ((String) -> Void)?

    /// 存具体类型而非 `MarketDataSource`：需要读轮询器的存活信号
    /// `lastRoundFinishedAt`，用它区分"网络不通"与"轮询器卡死"。
    private var source: RacingFuturesRestSource?
    private var stallTimer: Timer?

    // MARK: - 永续守护参数

    /// 轮询器「卡死」判定阈值 —— **不是"网络不好"的判定**。
    ///
    /// 判据取的是「多久没有任何**轮次收尾**」，而不是「多久没有数据」。这个区别是本版的关键：
    /// - **网络断了**：轮次仍在每 2 秒正常收尾（只是每轮都全失败）→ **不做任何干预**，
    ///   网络一恢复、下一轮自然就拉到数据；
    /// - **轮询器自己卡死**（定时器丢失、计数异常）→ 长时间没有任何轮次收尾 → 才重建一次。
    ///
    /// 取 60 秒：轮询周期 2 秒，60 秒等于连续 30 轮都没收尾 —— 足够说明是它卡住了。
    /// （早先取 10 秒、判"没数据"，会把正常的网络抖动也判成卡死，触发无谓重建。）
    private static let pollerStallThreshold: TimeInterval = 60

    /// 自愈冷却：真正断网时避免高频重建（无谓耗电），也让每轮自愈有完整观察窗口。
    private static let recoveryCooldown: TimeInterval = 10

    private var lastRecoveryAt: Date?

    /// 当前源被激活（或重建）的时刻，用于「刚启动还没收到数据」的宽限判定。
    private var sourceActivatedAt = Date.distantPast

    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied: Bool?

    private init() {}

    // MARK: - 对外接口

    func start() {
        stop()

        let racing = RacingFuturesRestSource()
        source = racing

        // 来源切换（OKX ↔ Binance）时更新界面并通知报警引擎摘掉跨所跳变
        racing.onVenueChanged = { [weak self] name in
            guard let self = self else { return }
            LogCollector.shared.append("market: 切换数据源 → \(name)")
            self.activeSourceName = name
            self.onSourceChanged?(name)
        }

        // 行情源可能在任意线程回调，统一归拢到主线程后再改状态
        racing.onTick = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snapshot = snapshot
                self.tickCount += 1
                self.lastTickAt = snapshot.updatedAt
                self.onSnapshot?(snapshot)
                self.tickPublisher.send(snapshot)   // 多播：实时活动等附加消费者
            }
        }

        racing.onState = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self, self.source === racing else { return }
                // 只更新状态（界面据此显示「失败：…」）。
                //
                // **刻意不在这里做任何"恢复"动作**：轮询器本身就是自愈的 ——
                // 一轮失败只是"这一轮没拿到"，2 秒后的下一轮自然重来。
                // 早先版本在这里顺手重建轮询器，结果三家全不通时变成
                // "每轮失败都触发一次重建"的循环，既无必要、又打乱了正常节奏。
                self.state = newState
            }
        }

        tickCount = 0
        sourceActivatedAt = Date()
        activeSourceName = racing.name
        // 注意：这里**不**调用 onSourceChanged。启动时报警引擎本就会把首笔快照
        // 当作基准价（见 AlertEngine），再通知一次只会白白多丢一笔。
        racing.start()
        startStallWatchdog()
        startNetworkMonitor()
    }

    func stop() {
        source?.stop()
        source = nil
        stallTimer?.invalidate()
        stallTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        networkWasSatisfied = nil
        lastRecoveryAt = nil
        state = .idle
        activeSourceName = "未启动"
        LogCollector.shared.append("market: 已全部停止")
    }

    /// 回到前台时调用：同样**只在"轮询器疑似卡死"时才动手**。
    ///
    /// 正常情况下什么都不做 —— 轮询器自己每 2 秒在跑，回到前台时最新价早就有了。
    func checkFreshness() {
        guard let source = source else { return }
        let since = source.lastRoundFinishedAt ?? sourceActivatedAt
        let idle = Date().timeIntervalSince(since)
        guard idle > Self.pollerStallThreshold else { return }
        LogCollector.shared.append(
            "market: 回到前台，轮询器已 \(Int(idle)) 秒没有轮次收尾 → 重建一次"
        )
        forceRecover(reason: "回到前台")
    }

    // MARK: - 自愈闭环

    /// 轮询器存活看门狗：每 5 秒核对一次「轮询器还在不在转」。
    ///
    /// 注意它**不看有没有数据**，只看有没有轮次收尾 —— 因此网络中断期间它完全不介入，
    /// 只有轮询器真的卡死才动手。详见 `pollerStallThreshold`。
    private func startStallWatchdog() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let source = self.source else { return }
            let since = source.lastRoundFinishedAt ?? self.sourceActivatedAt
            let idle = Date().timeIntervalSince(since)
            guard idle > Self.pollerStallThreshold else { return }
            self.attemptRecovery(reason: "轮询器 \(Int(idle)) 秒没有任何轮次收尾")
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// 恢复入口：重建轮询器。
    ///
    /// 与 WS 版相比这里简单得多：没有"连接"可以半死，轮询器本身也不需要复杂重建，
    /// 但**重启一次仍然有用** —— 它能清掉可能卡住的在途请求（`pending` 计数）。
    private func attemptRecovery(reason: String) {
        guard canRecoverNow() else { return }
        lastRecoveryAt = Date()

        guard let source = source else { return }
        LogCollector.shared.append("market: \(reason) → 重建 \(activeSourceName)")
        source.stop()
        sourceActivatedAt = Date()   // 重建后重新开始计时
        source.start()
    }

    /// 绕过冷却立即重建（目前只有「回到前台且疑似卡死」用得到）。
    private func forceRecover(reason: String) {
        lastRecoveryAt = nil
        attemptRecovery(reason: reason)
    }

    private func canRecoverNow() -> Bool {
        guard let last = lastRecoveryAt else { return true }
        return Date().timeIntervalSince(last) >= Self.recoveryCooldown
    }

    // MARK: - 网络状态监听

    /// 网络由「不可达」恢复为「可达」时立即补一次 —— 断网恢复的关键路径。
    ///
    /// 说明：只处理「恢复」这一跳；Wi-Fi 与蜂窝互切等「连接仍在但已失效」的场景
    /// 由看门狗兜底（REST 下最多多等 2 秒，代价很小）。
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let satisfied = (path.status == .satisfied)
                let wasSatisfied = self.networkWasSatisfied
                self.networkWasSatisfied = satisfied

                if satisfied, wasSatisfied == false {
                    // 只记一行日志、不做任何动作：轮询器每 2 秒本来就会重试，
                    // 下一轮（≤2 秒）自然就拿到数据了。
                    LogCollector.shared.append("market: 网络已恢复，下一轮轮询将自然恢复")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "market.network"))
    }
}
