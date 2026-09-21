import Foundation

/// L1 主源：Gate 期货（永续）WebSocket。
///
/// 选型依据（2026-09-18 实测，关闭 VPN 直连）：
/// 连接并订阅成功 968ms，每秒一条 futures.tickers 更新。
/// 说明：原选的 *.binance.vision 公共数据域只提供现货（fapi 路径 404），
/// 而产品需要永续价格，故改用本源。
final class GateFuturesWebSocketSource: MarketDataSource {

    let name = "Gate 永续 WS"
    let tier = 1

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    private let url = URL(string: "wss://fx-ws.gateio.ws/v4/ws/usdt")!
    private let contract = "BTC_USDT"

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var isStopped = false

    /// 心跳间隔：协议级 ping 用于识破「半死连接」——
    /// 锁屏 / 后台后 TCP 可能被中间设备静默掐断，此时 receive() 不会回调 error，
    /// 客户端会一直傻等。定时 ping 一旦失败即可判定链路已断，交由上层自愈。
    private static let heartbeatInterval: TimeInterval = 15

    func start() {
        isStopped = false
        onState?(.connecting)
        LogCollector.shared.append("market[L1]: 连接 Gate 永续 WS")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        sendSubscribe()
        startHeartbeat()
        receiveLoop()
    }

    func stop() {
        isStopped = true
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onState?(.idle)
        LogCollector.shared.append("market[L1]: 已停止")
    }

    // MARK: - 心跳

    /// 定时发协议级 ping（服务端回 pong）。失败即判定链路已断并上报 `.failed`，
    /// 交由 TickerStore 的自愈闭环处理。
    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isStopped else { return }
            self.task?.sendPing { [weak self] error in
                guard let error = error else { return }
                LogCollector.shared.append("market[L1]: 心跳失败 \(error.localizedDescription)")
                DispatchQueue.main.async { self?.onState?(.failed("心跳失败")) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - 发送

    private func sendSubscribe() {
        let time = Int(Date().timeIntervalSince1970)
        let text = "{\"time\":\(time),\"channel\":\"futures.tickers\",\"event\":\"subscribe\",\"payload\":[\"\(contract)\"]}"
        task?.send(.string(text)) { [weak self] error in
            if let error = error {
                LogCollector.shared.append("market[L1]: 订阅发送失败 \(error.localizedDescription)")
                self?.onState?(.failed(error.localizedDescription))
            } else {
                LogCollector.shared.append("market[L1]: 订阅已发送")
            }
        }
    }

    // MARK: - 接收

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self, !self.isStopped else { return }

            switch result {
            case .failure(let error):
                LogCollector.shared.append("market[L1]: 接收失败 \(error.localizedDescription)")
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
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 只处理行情更新事件；订阅确认、ping 等其它消息忽略
        guard let event = root["event"] as? String, event == "update",
              let results = root["result"] as? [[String: Any]],
              let first = results.first,
              let lastText = first["last"] as? String,
              let last = Double(lastText) else {
            return
        }

        let change = Double(first["change_percentage"] as? String ?? "") ?? 0

        onTick?(TickerSnapshot(
            symbol: first["contract"] as? String ?? contract,
            displayName: "BTC / USDT  永续",
            last: last,
            changePercent: change,
            updatedAt: Date()
        ))
    }
}
