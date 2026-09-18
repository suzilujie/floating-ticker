import Foundation

/// L2 兜底源：Gate 期货（永续）REST 轮询。
///
/// 与 L1 同域，同域被封时会同时失效；存在意义是应对
/// "HTTPS 可通但 WebSocket 被干扰"的网络环境（实测直连 596ms）。
final class GateFuturesRestSource: MarketDataSource {

    let name = "Gate 永续 REST"
    let tier = 2

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    private let url = URL(string: "https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=BTC_USDT")!
    private var timer: Timer?
    private var isStopped = false

    func start() {
        isStopped = false
        onState?(.connecting)
        LogCollector.shared.append("market[L2]: 开始轮询（2 秒间隔）")

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        onState?(.idle)
        LogCollector.shared.append("market[L2]: 已停止")
    }

    private func poll() {
        guard !isStopped else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, !self.isStopped else { return }

            if let error = error {
                LogCollector.shared.append("market[L2]: 请求失败 \(error.localizedDescription)")
                self.onState?(.failed(error.localizedDescription))
                return
            }

            // 该接口根节点是数组
            guard let data = data,
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = array.first,
                  let lastText = first["last"] as? String,
                  let last = Double(lastText) else {
                return
            }

            let change = Double(first["change_percentage"] as? String ?? "") ?? 0

            self.onState?(.connected)
            self.onTick?(TickerSnapshot(
                symbol: first["contract"] as? String ?? "BTC_USDT",
                displayName: "BTC / USDT  永续",
                last: last,
                changePercent: change,
                updatedAt: Date()
            ))
        }.resume()
    }
}
