import Foundation

/// OKX 永续（SWAP）WebSocket 源。
///
/// 定位：**条件性 L1 主源** —— 只有在启动探测判定「OKX 可达」时才会被启用。
/// 直连环境下它不可达（`ws.okx.com` 被 TLS 层阻断、`www.okx.com` 遭 DNS 污染
/// 至 169.254.0.2）；挂代理时实测 WS 924ms 可用（见设计文档 4.5 与 4.6）。
///
/// 与 Gate 源的两处关键差异：
///   1) **涨跌幅需自算**：接口只给 `last` 与 `open24h`，没有现成百分比；
///   2) **必须保活**：OKX 对空闲连接有超时要求，客户端需定时发 `ping`，
///      否则会被服务端断开 —— 表现是「连上约半分钟后莫名降级」，属假故障，最易踩坑。
final class OKXFuturesWebSocketSource: MarketDataSource {

    let name = "OKX 永续 WS"
    /// 与 Gate WS 同为 L1 候选；**实际优先级由 TickerStore 的源链顺序决定**
    /// （OKX 只在探测通过时才被插到链首，见 TickerStore.promoteOKXToPrimary）
    let tier = 1

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    private let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    private let instId = "BTC-USDT-SWAP"

    /// 保活间隔：OKX 约定连接空闲约 30 秒内需发 ping，这里取 20 秒留安全余量
    private static let pingInterval: TimeInterval = 20

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var isStopped = false

    func start() {
        isStopped = false
        onState?(.connecting)
        LogCollector.shared.append("market[OKX]: 连接 OKX 永续 WS")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        sendSubscribe()
        startPing()
        receiveLoop()
    }

    func stop() {
        isStopped = true
        stopPing()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onState?(.idle)
        LogCollector.shared.append("market[OKX]: 已停止")
    }

    // MARK: - 发送

    private func sendSubscribe() {
        // 消息格式沿用 scripts/check-perp.ps1 中已实测通过的订阅报文
        let text = "{\"op\":\"subscribe\",\"args\":[{\"channel\":\"tickers\",\"instId\":\"\(instId)\"}]}"
        task?.send(.string(text)) { [weak self] error in
            if let error = error {
                LogCollector.shared.append("market[OKX]: 订阅发送失败 \(error.localizedDescription)")
                self?.onState?(.failed(error.localizedDescription))
            } else {
                LogCollector.shared.append("market[OKX]: 订阅已发送")
            }
        }
    }

    /// 保活：定时发送文本 `ping`（OKX 约定，服务端回 `pong`）。
    ///
    /// 不加这个会踩「连上约半分钟后被断开」的坑（见类注释第 2 点）。
    /// 发送失败只记日志，不主动报 failed —— 单次 ping 失败不足以判定链路已断，
    /// 真正的断链会由 receive 回调的 error 暴露。
    private func startPing() {
        stopPing()
        let timer = Timer(timeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            self?.task?.send(.string("ping")) { error in
                if let error = error {
                    LogCollector.shared.append("market[OKX]: ping 发送失败 \(error.localizedDescription)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - 接收

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self, !self.isStopped else { return }

            switch result {
            case .failure(let error):
                LogCollector.shared.append("market[OKX]: 接收失败 \(error.localizedDescription)")
                self.onState?(.failed(error.localizedDescription))

            case .success(let message):
                self.onState?(.connected)
                if case .string(let text) = message {
                    self.handle(text)
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        // `pong`、订阅确认等非 JSON / 非行情消息在此一并忽略
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 只有行情推送带 data 数组；event/错误回执没有
        guard let arg = root["arg"] as? [String: Any],
              arg["channel"] as? String == "tickers",
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let lastText = first["last"] as? String,
              let last = Double(lastText) else {
            return
        }

        // 该接口无涨跌幅字段，用 24 小时开盘价自行计算（与 CoinEx 源同一套算法）
        let open = Double(first["open24h"] as? String ?? "") ?? 0
        let change = open > 0 ? (last - open) / open * 100 : 0

        onTick?(TickerSnapshot(
            symbol: first["instId"] as? String ?? instId,
            displayName: "BTC / USDT  永续",
            last: last,
            changePercent: change,
            updatedAt: Date()
        ))
    }
}
