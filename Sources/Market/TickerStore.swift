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
/// 仍然保留的三层守卫（REST 也会失败，只是故障形态简单得多）：
///   1) **数据停滞看门狗**：超过 `stallThreshold` 秒无数据即重建轮询器 —— 永不放弃
///   2) **网络状态监听**：网络由「不可达」恢复为「可达」时立即补一次
///   3) **回到前台检查**：App 回到前台时立刻核对数据新鲜度，停滞则立即自愈
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

    private var source: MarketDataSource?
    private var stallTimer: Timer?

    // MARK: - 永续守护参数

    /// 停滞阈值：轮询周期 2 秒，超过该秒数仍无数据即判定停滞并开始自愈。
    /// 取 10 秒 = 容忍连续 5 次轮询失败，既不至于误判，也不让用户干等太久。
    private static let stallThreshold: TimeInterval = 10

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
                self.state = newState
                if case .failed(let reason) = newState {
                    self.attemptRecovery(reason: "连接失败（\(reason)）")
                }
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

    /// 回到前台时调用：若数据已停滞则立即自愈，不必等看门狗的下一个检查周期。
    func checkFreshness() {
        let gap = Date().timeIntervalSince(referenceTime)
        guard gap > Self.stallThreshold else { return }
        LogCollector.shared.append("market: 回到前台，检测到 \(Int(gap)) 秒无数据 → 立即自愈")
        forceRecover(reason: "回到前台")
    }

    // MARK: - 自愈闭环

    /// 当前源上一次「应该有数据」的参考时刻。
    ///
    /// 取「最后一条数据时间」与「本源激活时刻」的较晚者 ——
    /// 这样刚启动/重建源时会有一段宽限期，不会因「还没拿到第一笔」而误判停滞。
    private var referenceTime: Date {
        if let last = lastTickAt, last > sourceActivatedAt { return last }
        return sourceActivatedAt
    }

    /// 停滞看门狗：每 5 秒核对一次数据新鲜度。
    private func startStallWatchdog() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let gap = Date().timeIntervalSince(self.referenceTime)
            guard gap > Self.stallThreshold else { return }
            self.attemptRecovery(reason: "\(Int(gap)) 秒无数据")
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

    /// 供「网络恢复 / 回到前台」使用：绕过冷却，立即恢复。
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
                    LogCollector.shared.append("market: 网络已恢复 → 立即补一次行情")
                    self.forceRecover(reason: "网络恢复")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "market.network"))
    }
}
