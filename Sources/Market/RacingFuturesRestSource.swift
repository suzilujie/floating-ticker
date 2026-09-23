import Foundation

/// 双源竞速的永续行情源：**同时**向 OKX 与 Binance 各拉一次，先返回者胜。
///
/// 三条设计要点，按重要性排序：
///
/// 1. **REST 取代 WS 的根本理由**：REST 每次请求都是独立的，**没有"连接状态"可以半死**。
///    WS 在真机上屡屡进入"TCP 还活着但不推数据、且不报错"的半死态，只能靠看门狗兜底，
///    代价是十几秒的行情空档；REST 的失败是明确的失败，下一个周期自然重试。
///
/// 2. **粘住当前的所，避免两个所之间横跳**：
///    两家交易所有基差（同一时刻的永续价差约 0.01%~0.09%，8 万价位上就是几十美元）。
///    若每一轮都"谁快用谁"，价格会每 2 秒跳一次 —— 不只是肉眼可见的抖动，
///    更会让报警的「穿越判定」被跨所跳变反复污染（上层每收到一次源变更就会重置基准价，
///    重置太频繁等于报警失效）。
///    因此策略是：**当前所在这一轮也拿到数据时就继续用它**；只有它失败/超时才交给另一家。
///    首轮则由先返回者决定 —— 即"先拉到谁的用谁的"。
///
/// 3. **备源结果要暂存**：当前所失败与备源成功是两条独立的完成回调，顺序不确定。
///    若备源先成功、当前所后失败，这一轮的数据不能被丢掉 —— 故见 `standby`。
final class RacingFuturesRestSource: MarketDataSource {

    let tier = 1

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    /// 当前生效的所发生变化时回调（含首次确定）。上层据此更新界面与报警基准。
    var onVenueChanged: ((String) -> Void)?

    /// 对外显示的源名。首次响应到达前是中性的占位名。
    var name: String { "\(currentVenue?.display ?? "OKX/Binance") 永续 REST" }

    // MARK: - 配置

    /// 轮询间隔：用户指定 2 秒。
    private static let interval: TimeInterval = 2.0

    /// 单次请求超时。刻意略大于轮询间隔：正常网络下（实测数百毫秒）节奏就是 2 秒；
    /// 若某家变慢，本轮会稍长，下一轮顺延（见 `poll` 里的 pending 判断），不会堆积请求。
    private static let timeout: TimeInterval = 2.5

    // MARK: - 两个候选所

    private enum Venue: String, CaseIterable {
        case okx
        case binance

        var display: String {
            switch self {
            case .okx: return "OKX"
            case .binance: return "Binance"
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
            }
        }
    }

    // MARK: - 运行时状态

    private var currentVenue: Venue?
    private var timer: Timer?
    private var isStopped = false

    /// 本轮尚未返回的请求数。非 0 时跳过本轮 —— 避免慢网络下请求堆积。
    private var pending = 0

    /// 本轮已失败的所
    private var failedThisRound = Set<Venue>()

    /// 备源本轮的暂存结果：当前所还没结论时先存着，它一旦失败就直接顶上。
    /// 没有这个暂存，会出现「备源先成功被忽略 → 当前所随后失败」→ 整轮数据白丢。
    private var standby: (venue: Venue, snapshot: TickerSnapshot)?

    /// 解析失败只完整打一次（含响应片段），避免每 2 秒刷屏
    private var didLogParseFailure = false

    // MARK: - 生命周期

    func start() {
        isStopped = false
        currentVenue = nil
        pending = 0
        failedThisRound.removeAll()
        standby = nil
        didLogParseFailure = false

        onState?(.connecting)
        LogCollector.shared.append(
            "market: 启动双源轮询（OKX + Binance，每 \(Int(Self.interval)) 秒，先返回者优先）"
        )

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()   // 立即拉一次，不等第一个周期
    }

    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        pending = 0
        standby = nil
        onState?(.idle)
        LogCollector.shared.append("market: 双源轮询已停止")
    }

    // MARK: - 轮询

    private func poll() {
        guard !isStopped, pending == 0 else { return }
        failedThisRound.removeAll()
        standby = nil
        pending = Venue.allCases.count
        for venue in Venue.allCases { fetch(venue) }
    }

    private func fetch(_ venue: Venue) {
        var request = URLRequest(url: venue.url)
        // 价格必须反映"此刻"，不能被任何缓存掩盖
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }

            // 解析放后台线程；状态变更统一回主线程（`pending` / `standby` 都是主线程独占）
            let outcome: Result<TickerSnapshot, String>
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

            DispatchQueue.main.async { self.handle(outcome, from: venue) }
        }.resume()
    }

    private func handle(_ outcome: Result<TickerSnapshot, String>, from venue: Venue) {
        guard !isStopped else { return }
        pending = max(pending - 1, 0)

        switch outcome {
        case .success(let snapshot):
            if currentVenue == nil || currentVenue == venue {
                deliver(venue: venue, snapshot: snapshot)
            } else if failedThisRound.contains(currentVenue!) {
                // 当前所本轮已失败 → 直接接管
                deliver(venue: venue, snapshot: snapshot)
            } else {
                // 当前所还没结论 → 先暂存，等它失败时顶上
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
            // 两家都失败才算真的失败（只有一家失败时另一家会顶上）
            if failedThisRound.count == Venue.allCases.count {
                onState?(.failed(reason))
            }
        }
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

    /// 解析两家交易所的 ticker 响应（已核对各自的官方字段名）。
    ///
    /// - OKX：`{"code":"0","data":[{"instId":"…","last":"…","open24h":"…"}]}`
    ///   **OKX 不返回 24h 涨跌幅**，只给 `open24h`（24 小时前开盘价），百分比需自己算。
    /// - Binance：`{"symbol":"BTCUSDT","lastPrice":"…","priceChangePercent":"0.71"}`
    ///   `priceChangePercent` 已经是百分数值，直接用。
    private static func parse(_ data: Data, venue: Venue) -> TickerSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch venue {
        case .okx:
            guard let list = root["data"] as? [[String: Any]],
                  let first = list.first,
                  let last = Double(first["last"] as? String ?? "") else { return nil }
            let open24h = Double(first["open24h"] as? String ?? "") ?? 0
            let change = open24h > 0 ? (last / open24h - 1) * 100 : 0
            return TickerSnapshot(
                symbol: "BTC-USDT-SWAP",
                displayName: "BTC / USDT  永续",
                last: last,
                changePercent: change,
                updatedAt: Date()
            )

        case .binance:
            guard let last = Double(root["lastPrice"] as? String ?? "") else { return nil }
            let change = Double(root["priceChangePercent"] as? String ?? "") ?? 0
            return TickerSnapshot(
                symbol: "BTCUSDT",
                displayName: "BTC / USDT  永续",
                last: last,
                changePercent: change,
                updatedAt: Date()
            )
        }
    }
}
