import Combine
import Foundation
import Network

/// 行情状态聚合：持有最新快照、当前数据源与连接状态，
/// 并在主源失败时按层级降级（L1 → L2 → L3）。
///
/// **永续更新保障（本版重点）**：产品要求「只要 App 开着就必须一直更新行情，
/// 除非网络真的断了或手机关机」。为此在原有「失败才降级」之上，补齐了完整的自愈闭环。
///
/// 要解决的根因（真机复现：锁屏回来后行情不再更新）：
/// 锁屏 / 后台时 iOS 会静默掐断 TCP（NAT 超时），而客户端正阻塞在 `receive()`，
/// 收不到任何 error —— 连接进入「半死」状态：不报失败，也永远收不到数据。
/// 旧实现里看门狗只写一行日志「疑似中断」就没了，于是永久卡住。
///
/// 四层守卫：
///   1) **数据停滞看门狗**：超过 `stallThreshold` 秒无任何推送即判定停滞，主动重建当前源；
///      连续重建无效则切换下一层；**到底后回绕到链首**继续重试 —— 永不放弃。
///   2) **网络状态监听**：网络由「不可达」恢复为「可达」时立即重建（断网恢复的关键路径）。
///   3) **回到前台检查**：App 回到前台时立刻核对数据新鲜度，停滞则立即自愈。
///   4) **连接级心跳**：由各数据源自身实现（见各 WS 源的 sendPing），
///      用于把「半死连接」暴露成 `.failed` 回调，加速上面的自愈触发。
///
/// 线程约束：所有对外状态变更统一在主线程（行情源的回调在此处 `DispatchQueue.main.async`
/// 归拢），故下游（界面、报警引擎）无需再处理线程问题。
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

    // MARK: - 永续守护参数

    /// 停滞阈值：正常约每秒一条推送（Gate WS 实测每秒一条），
    /// 超过该秒数仍无数据即判定停滞并开始自愈。
    /// 取 10 秒是为了容忍偶发的推送空档，又不至于让用户等太久。
    private static let stallThreshold: TimeInterval = 10

    /// 自愈冷却：真正断网时避免高频重连（无谓耗电），也让每轮自愈有完整观察窗口。
    private static let recoveryCooldown: TimeInterval = 10

    /// 同一数据源内最多连续重建次数，超过则切换下一层。
    private static let maxRestartPerSource = 2

    private var lastRecoveryAt: Date?
    private var restartCount = 0

    /// 当前源被激活（或重建）的时刻，用于「刚切换还没收到数据」的宽限判定。
    private var sourceActivatedAt = Date.distantPast

    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied: Bool?

    /// 上一次重新评估 OKX 可达性的时刻（节流用：网络抖动会连续触发多次路径变化）
    private var lastOKXProbeAt: Date?
    /// 定期重评 OKX 的定时器：兜住「网络形态变了但 NWPathMonitor 未回调」的情况
    private var okxReevalTimer: Timer?

    /// OKX 最近一次连接失败的时刻。
    ///
    /// 用于「只要 OKX 可达就用 OKX」这条策略的**防横跳冷却**：
    /// 探测已改为直接验证 WS 端点（可达即真的能连上），但长连接仍可能因
    /// 网络抖动、服务端限流而在建立后不久掉线；若无冷却，就会出现
    /// 「切到 OKX → 掉线降级到 Gate → 探测又说可达 → 立刻切回」的反复抖动，
    /// 表现为价格在两个交易所之间高频跳变。
    private var okxLastFailureAt: Date?
    private static let okxSwitchCooldown: TimeInterval = 120

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
        startNetworkMonitor()
        startOKXReevaluation()
        probeOKXAvailability(generation: probeGeneration)
    }

    func stop() {
        probeGeneration += 1   // 作废在途探测，避免迟到回调重启源链
        currentSource?.stop()
        currentSource = nil
        sources = []
        stallTimer?.invalidate()
        stallTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        networkWasSatisfied = nil
        okxReevalTimer?.invalidate()
        okxReevalTimer = nil
        lastOKXProbeAt = nil
        okxLastFailureAt = nil
        lastRecoveryAt = nil
        restartCount = 0
        state = .idle
        activeSourceName = "未启动"
        LogCollector.shared.append("market: 已全部停止")
    }

    /// 回到前台时调用：若数据已停滞则立即自愈，不必等看门狗的下一个检查周期。
    func checkFreshness() {
        // 回到前台顺带重评一次源优先级：用户很可能刚在外面开关过 VPN
        reevaluateOKX()

        let gap = Date().timeIntervalSince(referenceTime)
        guard gap > Self.stallThreshold else { return }
        LogCollector.shared.append("market: 回到前台，检测到 \(Int(gap)) 秒无数据 → 立即自愈")
        forceRecover(reason: "回到前台")
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
        restartCount = 0
        sourceActivatedAt = Date()

        // 行情源可能在任意线程回调，统一归拢到主线程后再改状态
        source.onTick = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snapshot = snapshot
                self.tickCount += 1
                self.lastTickAt = snapshot.updatedAt
                self.restartCount = 0            // 数据回来了，清空自愈计数
                self.onSnapshot?(snapshot)
                self.tickPublisher.send(snapshot)   // 多播：实时活动等附加消费者
            }
        }

        source.onState = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 只接受当前源的状态，避免已停用源的迟到回调干扰
                guard self.currentSource === source else { return }
                self.state = newState
                if case .failed(let reason) = newState {
                    // 记录 OKX 的失败时刻，供「可达就切回」的防横跳冷却使用
                    if source is OKXFuturesWebSocketSource {
                        self.okxLastFailureAt = Date()
                    }
                    self.attemptRecovery(reason: "连接失败（\(reason)）")
                }
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

    // MARK: - 自愈闭环

    /// 当前源上一次「应该有数据」的参考时刻。
    ///
    /// 取「最后一条数据时间」与「本源激活时刻」的较晚者 ——
    /// 这样刚切换/重建源时会有一段宽限期，不会因「连接还没建好」而误判停滞。
    private var referenceTime: Date {
        if let last = lastTickAt, last > sourceActivatedAt { return last }
        return sourceActivatedAt
    }

    /// 停滞看门狗：每 5 秒核对一次数据新鲜度。
    ///
    /// 注意这里**不做任何恢复计数的清零** —— 计数只在真正收到数据（onTick）时清空，
    /// 否则「重建后尚未收到数据」的宽限期会把计数抹掉，导致永远降不了级。
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

    /// 统一的恢复入口：先重建当前源，反复无效则切换下一层（到底后回绕链首）。
    ///
    /// 这条闭环是「任何情况下都恢复」的核心 —— 它不关心失效原因（半死连接、
    /// 服务器无推送、切换网络丢连接），只要「没有数据」就会一路重试下去。
    private func attemptRecovery(reason: String) {
        guard canRecoverNow() else { return }
        lastRecoveryAt = Date()

        if restartCount < Self.maxRestartPerSource {
            restartCount += 1
            LogCollector.shared.append(
                "market: \(reason) → 重建 \(activeSourceName)（第 \(restartCount)/\(Self.maxRestartPerSource) 次）"
            )
            restartCurrentSource()
        } else {
            restartCount = 0
            LogCollector.shared.append("market: \(reason) → \(activeSourceName) 反复无数据，切换数据源")
            moveToNextSource()
        }
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

    /// 重建当前源：停掉再启动，丢弃可能已「半死」的连接。
    private func restartCurrentSource() {
        guard let source = currentSource else { return }
        source.stop()
        sourceActivatedAt = Date()   // 重建后重新开始计时
        source.start()
    }

    /// 切到下一层；已到最后一层则回绕到链首继续重试（永不放弃）。
    ///
    /// 回绕的意义：三层源同时被网络问题打挂后，一旦网络恢复，必须能重新用上最好的源，
    /// 而不是卡在「已无更低层级可降级」的终态。
    private func moveToNextSource() {
        currentSource?.stop()
        if currentIndex + 1 < sources.count {
            currentIndex += 1
        } else {
            currentIndex = 0
            LogCollector.shared.append("market: 已到最后一层，回绕链首重试")
        }
        activateCurrentSource()
    }

    // MARK: - 网络状态监听

    /// 网络由「不可达」恢复为「可达」时立即重建源 —— 断网恢复的关键路径。
    ///
    /// 说明：只处理「恢复」这一跳；Wi-Fi 与蜂窝互切等连接仍在但已失效的场景由看门狗兜底。
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
                    LogCollector.shared.append("market: 网络已恢复 → 立即重建当前源")
                    self.forceRecover(reason: "网络恢复")
                }

                // 网络路径变化（开关 VPN 必走这里）→ 重新评估 OKX 优先级。
                // 「哪个源最快」会随网络环境翻转（直连时 OKX 不可达、挂代理时 OKX 最快），
                // 不重评就会一直停留在旧选择上 —— 这正是 R17 记录的已知边界。
                if satisfied {
                    self.reevaluateOKX()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "market.network"))
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
            self.applyOKXAvailability(isReachable, generation: generation)
        }
    }

    // MARK: - OKX 优先级动态重评（网络环境变化时）

    /// 定期重评 OKX 可达性（高频：每 5 秒）。
    ///
    /// 为什么除路径回调外还要定期兜底：部分 TUN 模式 VPN 开关时不改动
    /// NWPathMonitor 关注的路径状态（只在接口层变化），回调可能不触发。
    ///
    /// 间隔取 5 秒，是为了「OKX 一旦可达就尽快切过去」。为让这个高频可持续，
    /// `reevaluateOKX` 里做了两条短路（已在用 OKX / 处于失败冷却），
    /// 避免无意义的探测与 TLS 握手（否则空闲时每天上万次，纯属浪费电量与流量）。
    private func startOKXReevaluation() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.reevaluateOKX()
        }
        RunLoop.main.add(timer, forMode: .common)
        okxReevalTimer = timer
    }

    /// 重新评估 OKX 是否可达并据此调整源链。
    private func reevaluateOKX() {
        // 短路一：已经在用 OKX —— 没有可切换的目标。
        // 「OKX 自己掉线」由数据源心跳与停滞看门狗负责发现，不依赖这里的探测。
        if currentSource is OKXFuturesWebSocketSource { return }

        // 短路二：处于失败冷却期内，即便探测到可达也不会切（见 okxLastFailureAt），
        // 直接省掉这段无意义的探测。
        if let lastFail = okxLastFailureAt,
           Date().timeIntervalSince(lastFail) < Self.okxSwitchCooldown {
            return
        }

        // 节流：网络抖动会连续触发多次路径变化，没必要每次都探（阈值小于 5 秒定期，
        // 保证定期探测不会被自己的节流挡掉）
        if let last = lastOKXProbeAt, Date().timeIntervalSince(last) < 3 { return }
        lastOKXProbeAt = Date()

        let generation = probeGeneration
        SourceProbe.probeOKX(log: false) { [weak self] isReachable in
            guard let self = self else { return }   // 回调已在主线程
            self.applyOKXAvailability(isReachable, generation: generation)
        }
    }

    /// 根据 OKX 可达性调整源链：
    /// - 可达且链上还没有 OKX → 提升为首选并切换过去
    /// - 不可达且链上有 OKX → 从链上移除（若正在用则立即切回 Gate 链）
    /// - 结果与现状一致 → 什么都不做（避免无谓的源切换，切换会让价格跳一下）
    /// 根据 OKX 可达性调整源链。
    ///
    /// 策略（用户要求）：**只要 OKX 可达，就应该用 OKX** —— 因此除「可达则启用」外，
    /// 还包含「OKX 已在链上、但当前没在用（曾失败被降级）→ 切回 OKX」。
    private func applyOKXAvailability(_ reachable: Bool, generation: Int) {
        guard probeGeneration == generation else { return }

        let okxPresent = sources.contains { $0 is OKXFuturesWebSocketSource }
        let okxActive = currentSource is OKXFuturesWebSocketSource

        guard reachable else {
            if okxPresent { demoteOKX() }
            return
        }

        // 防横跳：OKX 刚连接失败过时暂不切（详见 okxLastFailureAt 注释）
        if let last = okxLastFailureAt, Date().timeIntervalSince(last) < Self.okxSwitchCooldown {
            if !okxPresent {
                LogCollector.shared.append("market: OKX 探测可达，但刚连接失败过，暂不启用")
            } else if !okxActive {
                LogCollector.shared.append("market: OKX 探测可达，但刚连接失败过，暂不切回")
            }
            return
        }

        if !okxPresent {
            promoteOKXToPrimary()
        } else if !okxActive {
            switchToOKX()
        }
    }

    /// OKX 已在源链上且探测可达，但当前用的是别的源 → 切回 OKX。
    private func switchToOKX() {
        guard let idx = sources.firstIndex(where: { $0 is OKXFuturesWebSocketSource }) else { return }
        guard currentIndex != idx else { return }

        LogCollector.shared.append("market: OKX 可达且当前未使用 → 切回 OKX 永续 WS")
        currentSource?.stop()
        currentIndex = idx
        activateCurrentSource()
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

    /// OKX 不再可达（例如关闭了代理）：从源链移除，避免继续用一个必然失败的源。
    ///
    /// 若当前正在用 OKX，则立即切回链首（即 Gate 链的第一个源），
    /// 而不是干等看门狗判定停滞再降级 —— 这样关闭 VPN 后能立刻切走。
    private func demoteOKX() {
        guard let idx = sources.firstIndex(where: { $0 is OKXFuturesWebSocketSource }) else { return }

        let wasActive = (currentIndex == idx)
        sources.remove(at: idx)

        if wasActive {
            LogCollector.shared.append("market: OKX 已不可达 → 立即切回 Gate 链")
            currentIndex = 0
            activateCurrentSource()
        } else {
            // 当前源排在 OKX 之后时，索引整体前移一位，保持指向同一个源
            if currentIndex > idx { currentIndex -= 1 }
            LogCollector.shared.append("market: OKX 已不可达，已从源链移除")
        }
    }
}
