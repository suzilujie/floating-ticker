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
    private var isStopped = false

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
        receiveLoop()
    }

    func stop() {
        isStopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onState?(.idle)
        LogCollector.shared.append("market[L1]: 已停止")
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
