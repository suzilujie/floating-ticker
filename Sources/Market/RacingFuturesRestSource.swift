import Foundation

/// 多源 REST 行情：**OKX 与 Binance 同时竞速，Gate 作为兜底**。
///
/// 四条设计要点，按重要性排序：
///
/// 1. **REST 取代 WS 的根本理由**：REST 每次请求都是独立的，**没有"连接状态"可以半死**。
///    WS 在真机上屡屡进入"TCP 还活着但不推数据、且不报错"的半死态，只能靠看门狗兜底，
///    代价是十几秒的行情空档；REST 的失败是明确的失败，下一个周期自然重试。
///
/// 2. **粘住当前的所，避免两个所之间横跳**：
///    两家交易所有基差（同一时刻永续价差约 0.01%~0.09%，8 万价位上就是几十美元）。
///    若每一轮都"谁快用谁"，价格会每 2 秒跳一次 —— 不只是肉眼可见的抖动，
///    更会让报警的「穿越判定」被跨所跳变反复污染（上层每收到一次源变更就重置基准价，
///    重置太频繁等于报警失效）。
///    因此策略是：**当前所在这一轮也拿到数据时就继续用它**；只有它失败/超时才交给另一家。
///    首轮由先返回者决定 —— 即"先拉到谁的用谁的"。
///
/// 3. **Gate 是兜底，不是第三个竞速者**：只有当 OKX 与 Binance 本轮**全部失败**时，
///    才额外发一个 Gate 请求。这样正常情况下多源冗余的代价为零（少一次请求、少一份耗电），
///    而在两家同时抽风（比如都在维护、或代理规则把这俩都挡了）时仍有行情可用。
///
/// 4. **备源结果要暂存**：当前所失败与备源成功是两条独立的完成回调，顺序不确定。
///    若备源先成功、当前所后失败，这一轮的数据不能被丢掉 —— 故见 `standby`。
final class RacingFuturesRestSource: MarketDataSource {

    let tier = 1

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    /// 当前生效的所发生变化时回调（含首次确定）。上层据此更新界面与报警基准。
    var onVenueChanged: ((String) -> Void)?

    /// 对外显示的源名。首次响应到达前是中性的占位名。
    ///
    /// 刻意拆成两句、而不是写成 `"\(a ?? "b")"`：嵌套字符串字面量在插值里的
    /// 可读性差，兼容性也容易踩坑，拆开最稳。
    var name: String {
        let venue = currentVenue?.display ?? "OKX/Binance"
        return "\(venue) 永续 REST"
    }

    // MARK: - 配置

    /// 轮询间隔：用户指定 2 秒。
    private static let interval: TimeInterval = 2.0

    /// 单次请求超时。刻意略大于轮询间隔：正常网络下（实测数百毫秒）节奏就是 2 秒；
    /// 若某家变慢，本轮会稍长，下一轮顺延（见 `poll` 里的 pending 判断），不会堆积请求。
    private static let timeout: TimeInterval = 2.5

    // MARK: - 候选源

    private enum Venue: String, CaseIterable {
        case okx
        case binance
        case gate

        /// 0 = 主源（每轮**同时**发出，先返回者优先）；1 = 兜底源（仅主源全败时启用）。
        var rank: Int {
            switch self {
            case .okx, .binance: return 0
            case .gate: return 1
            }
        }

        var display: String {
            switch self {
            case .okx: return "OKX"
            case .binance: return "Binance"
            case .gate: return "Gate"
            }
        }

        var url: URL {
            switch self {
            case .okx:
                // OKX v5 行情：永续合约 BTC-USDT-SWAP
                return URL(string: "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP")!
            case .binance:
                // Binance **USDT 本位永续**（fapi），与 OKX 的 SWAP 同类；
                // 用现货（api.binance.com）会引入"现货 vs 永续"的额外基差，故不用。
                return URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=BTCUSDT")!
            case .gate:
                return URL(string: "https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=BTC_USDT")!
            }
        }
    }

    /// 每轮同时竞速的主源
    private static let primaries: [Venue] = [.okx, .binance]
    /// 主源本轮全部失败时才启用的兜底源
    private static let fallback: Venue = .gate

    /// 单次请求的结局。
    ///
    /// 为什么不用 `Result<TickerSnapshot, String>`：**`Result` 的 `Failure` 必须符合
    /// `Error`，而 `String` 不符合** —— 那样写会直接编译失败（本项目踩过这个坑）。
    private enum Outcome {
        case success(TickerSnapshot)
        case failure(String)
    }

    // MARK: - 运行时状态

    private var currentVenue: Venue?
    /// 下一次轮询的一次性定时器（每次轮次收尾后重新安排，见 `scheduleNextPoll`）
    private var timer: Timer?
    /// 上一次**发起**轮询的时刻，作为"目标节拍"的基准
    private var lastPollAt: Date?
    private var isStopped = false

    /// 本轮尚未返回的请求数（含兜底）。非 0 时跳过本轮 —— 避免慢网络下请求堆积。
    private var pending = 0
    /// 主源中尚未返回的个数
    private var primariesPending = 0
    /// 本轮主源是否已有成功（有则不必再拉兜底源）
    private var primarySucceeded = false
    /// 兜底源本轮是否已发出
    private var fallbackSent = false

    /// 本轮已失败的所
    private var failedThisRound = Set<Venue>()

    /// 备源本轮的暂存结果：当前所还没结论时先存着，它一旦失败就直接顶上。
    /// 没有这个暂存，会出现「备源先成功被忽略 → 当前所随后失败」→ 整轮数据白丢。
    private var standby: (venue: Venue, snapshot: TickerSnapshot)?

    /// 解析失败只完整打一次（含响应片段），避免每 2 秒刷屏
    private var didLogParseFailure = false

    /// 最近一次「轮次收尾」的时刻（本轮所有请求都已有结论）。
    ///
    /// 用途：让上层能区分两种"没数据"，这是**不做无谓重建的关键**：
    /// - **网络不通**：轮次仍在每 2 秒正常收尾（每轮都以"全失败"结束）→ 上层什么都不用做，
    ///   网络恢复后下一轮自然就拉到数据了；
    /// - **轮询器卡死**：长时间没有任何轮次收尾（定时器丢失、计数乱了）→ 才需要重建。
    private(set) var lastRoundFinishedAt: Date?

    /// 轮次代次：`start` / `stop` / 每轮轮询都会自增。
    ///
    /// 每条请求都带着"发出时的代次"，回调时代次对不上就**整条丢弃**。
    /// 为什么必须有：`attemptRecovery` 里的 `stop()` 与 `start()` 是**同步**接上的，
    /// 而上一轮的在途回调要到稍后才到达 —— 若不加代次，它们会去扣**本轮**的
    /// `pending` 计数，让计数与实际在途请求错位（表现就是轮询节奏乱掉、甚至停摆）。
    private var generation = 0

    // MARK: - 生命周期

    func start() {
        isStopped = false
        currentVenue = nil
        lastRoundFinishedAt = nil
        generation += 1        // 作废上一轮遗留的所有在途回调
        resetRound()

        onState?(.connecting)
        LogCollector.shared.append(
            "market: 启动 REST 轮询（目标节拍 \(Int(Self.interval)) 秒）"
                + "｜主源 OKX + Binance 竞速，兜底 \(Self.fallback.display)"
        )

        timer?.invalidate()
        timer = nil
        poll()   // 立即拉一次；之后的节拍由「每轮收尾后安排下一次」驱动
    }

    func stop() {
        isStopped = true
        generation += 1        // 作废在途回调
        timer?.invalidate()
        timer = nil
        resetRound()
        onState?(.idle)
        LogCollector.shared.append("market: REST 轮询已停止")
    }

    private func resetRound() {
        pending = 0
        lastPollAt = nil
        primariesPending = 0
        primarySucceeded = false
        fallbackSent = false
        failedThisRound.removeAll()
        standby = nil
        didLogParseFailure = false
    }

    // MARK: - 轮询

    private func poll() {
        guard !isStopped, pending == 0 else { return }
        lastPollAt = Date()
        generation += 1
        let gen = generation
        failedThisRound.removeAll()
        standby = nil
        primarySucceeded = false
        fallbackSent = false
        primariesPending = Self.primaries.count
        pending = Self.primaries.count
        for venue in Self.primaries { fetch(venue, generation: gen) }
    }

    private func fetch(_ venue: Venue, generation gen: Int) {
        var request = URLRequest(url: venue.url)
        // 价格必须反映"此刻"，不能被任何缓存掩盖
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }

            // 解析放后台线程；状态变更统一回主线程（`pending` / `standby` 都是主线程独占）
            let outcome: Outcome
            if let error = error {
                outcome = .failure(error.localizedDescription)
            } else if let data = data, let snapshot = Self.parse(data, venue: venue) {
                outcome = .success(snapshot)
            } else {
                outcome = .failure("响应无法解析")
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    guard !self.didLogParseFailure else { return }
                    self.didLogParseFailure = true
                    LogCollector.shared.append(
                        "market[\(venue.display)]: 响应解析失败，请核对字段名｜body=\(body.prefix(160))"
                    )
                }
            }

            DispatchQueue.main.async { self.handle(outcome, from: venue, generation: gen) }
        }.resume()
    }

    private func handle(_ outcome: Outcome, from venue: Venue, generation gen: Int) {
        // 代次不符 = 这是上一轮（或重启前）的迟到回调 → 整条丢弃，
        // 否则它会扣错本轮的计数（见 `generation` 注释）
        guard !isStopped, gen == generation else { return }
        pending = max(pending - 1, 0)
        if venue.rank == 0 { primariesPending = max(primariesPending - 1, 0) }

        switch outcome {
        case .success(let snapshot):
            if venue.rank == 0 { primarySucceeded = true }
            if shouldAdopt(venue) {
                deliver(venue: venue, snapshot: snapshot)
            } else {
                // 等当前所的结论，先存着（见 `standby` 注释）
                standby = (venue, snapshot)
            }

        case .failure(let reason):
            failedThisRound.insert(venue)
            if currentVenue == venue {
                LogCollector.shared.append("market[\(venue.display)]: 本轮失败（\(reason)）→ 交由备源")
                if let parked = standby {
                    standby = nil
                    deliver(venue: parked.venue, snapshot: parked.snapshot)
                }
            }
            // 所有候选都失败才算真的失败（只要有一家成功，这轮就是好的）
            if failedThisRound.count == Venue.allCases.count {
                onState?(.failed(reason))
            }
        }

        // 主源阶段收尾：主源一个都没成功 → 启动兜底源（Gate）。
        //
        // 这里必须再校验一次代次：上面的 `onState?(.failed)` 会让上层**立刻重启本源**
        // （看门狗自愈），而重启是同步的 —— 不校验的话，这段会在新的一轮里
        // 再补发一个多余的 Gate 请求，把 `pending` 计数打乱。
        if gen == generation, primariesPending == 0, !primarySucceeded, !fallbackSent {
            fallbackSent = true
            pending += 1
            LogCollector.shared.append(
                "market: 主源本轮全部失败 → 改用兜底源 \(Self.fallback.display) REST"
            )
            fetch(Self.fallback, generation: gen)
        }

        // 轮次真正收尾：本轮所有请求（含兜底）都已有结论 —— 无论成败都算。
        // 这一行是上层"判断轮询器还活着"的唯一依据（见 `lastRoundFinishedAt`）。
        if gen == generation, pending == 0 {
            lastRoundFinishedAt = Date()
            scheduleNextPoll()
        }
    }

    /// 安排下一次轮询（一次性，每轮收尾后重新安排）。
    ///
    /// **为什么不用"固定重复定时器"**：重复定时器是踩在固定的 2 秒网格上的 ——
    /// 一旦某轮耗时略微超过 2 秒，就会**错过整整一格**，节奏直接掉到 4 秒
    /// （典型场景：某家源要等满 2.5 秒超时 → 轮询频率被砍半）。
    ///
    /// 这里按"目标节拍"来：下一次定在「上一次发起时刻 + interval」；若那一刻
    /// 已经过去（说明本轮比周期还长），就立刻发。于是实际节奏恒为
    /// `max(interval, 一轮耗时)`，不会被 2 秒网格放大。
    ///
    /// 副作用（已知并接受）：若某轮**永远不收尾**，这里就不会安排下一次 ——
    /// 那属于"轮询器卡死"，由 `TickerStore` 的看门狗负责重建。
    private func scheduleNextPoll() {
        timer?.invalidate()
        guard !isStopped else { return }

        let base = lastPollAt ?? Date()
        let delay = max(0, base.addingTimeInterval(Self.interval).timeIntervalSinceNow)
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(next, forMode: .common)
        self.timer = next
    }

    /// 是否应当**采用**这条结果（否则先暂存等当前所的结论）。
    ///
    /// 规则按优先级：
    ///  1. 还没有当前所 → 采用（首轮"先返回者胜"）
    ///  2. 就是当前所 → 采用（粘住，避免横跳）
    ///  3. 当前所本轮已失败 → 采用（顶上）
    ///  4. 当前所是兜底源、而这条来自主源 → 采用（**主源优先于兜底源**，
    ///     否则一旦掉到 Gate，主源恢复后也回不来 —— 而 Gate 的基差更大）
    private func shouldAdopt(_ venue: Venue) -> Bool {
        guard let current = currentVenue else { return true }
        if current == venue { return true }
        if failedThisRound.contains(current) { return true }
        if venue.rank == 0, current.rank > 0 { return true }
        return false
    }

    private func deliver(venue: Venue, snapshot: TickerSnapshot) {
        if currentVenue != venue {
            currentVenue = venue
            LogCollector.shared.append("market: 数据源 → \(name)")
            onVenueChanged?(name)
        }
        onState?(.connected)
        onTick?(snapshot)
    }

    // MARK: - 解析

    /// 解析三家交易所的 ticker 响应（字段名以各自官方文档为准）。
    ///
    /// - OKX：`{"code":"0","data":[{"instId":"…","last":"…","open24h":"…"}]}`
    ///   **OKX 不返回 24h 涨跌幅**，只给 `open24h`（24 小时前开盘价），百分比需自己算。
    /// - Binance：`{"symbol":"BTCUSDT","lastPrice":"…","priceChangePercent":"0.71"}`
    ///   `priceChangePercent` 已经是百分数值，直接用。
    /// - Gate：根节点是**数组**（与另外两家不同）：`[{"contract":"BTC_USDT","last":"…",
    ///   "change_percentage":"…"}]`，涨跌幅同样是百分数值。
    private static func parse(_ data: Data, venue: Venue) -> TickerSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        switch venue {
        case .okx:
            guard let object = root as? [String: Any],
                  let list = object["data"] as? [[String: Any]],
                  let first = list.first,
                  let last = Double(first["last"] as? String ?? "") else { return nil }
            let open24h = Double(first["open24h"] as? String ?? "") ?? 0
            let change = open24h > 0 ? (last / open24h - 1) * 100 : 0
            return snapshot(last: last, change: change, symbol: "BTC-USDT-SWAP")

        case .binance:
            guard let object = root as? [String: Any],
                  let last = Double(object["lastPrice"] as? String ?? "") else { return nil }
            let change = Double(object["priceChangePercent"] as? String ?? "") ?? 0
            return snapshot(last: last, change: change, symbol: "BTCUSDT")

        case .gate:
            guard let array = root as? [[String: Any]],
                  let first = array.first,
                  let last = Double(first["last"] as? String ?? "") else { return nil }
            let change = Double(first["change_percentage"] as? String ?? "") ?? 0
            return snapshot(last: last, change: change,
                            symbol: first["contract"] as? String ?? "BTC_USDT")
        }
    }

    private static func snapshot(last: Double, change: Double, symbol: String) -> TickerSnapshot {
        TickerSnapshot(
            symbol: symbol,
            displayName: "BTC / USDT  永续",
            last: last,
            changePercent: change,
            updatedAt: Date()
        )
    }
}
