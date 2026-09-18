import Foundation

/// L3 异构兜底源：CoinEx 永续 REST 轮询。
///
/// 与 Gate 属不同厂商、不同 CDN，用于抵御单域被封的情况
/// （实测直连 721ms 可用）。
/// 注意：该接口不直接给出涨跌幅，需由 last 与 open 计算。
final class CoinExFuturesRestSource: MarketDataSource {

    let name = "CoinEx 永续 REST"
    let tier = 3

    var onTick: ((TickerSnapshot) -> Void)?
    var onState: ((MarketState) -> Void)?

    private let url = URL(string: "https://api.coinex.com/v2/futures/ticker?market=BTCUSDT")!
    private var timer: Timer?
    private var isStopped = false

    func start() {
        isStopped = false
        onState?(.connecting)
        LogCollector.shared.append("market[L3]: 开始轮询（2 秒间隔）")

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
        LogCollector.shared.append("market[L3]: 已停止")
    }

    private func poll() {
        guard !isStopped else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, !self.isStopped else { return }

            if let error = error {
                LogCollector.shared.append("market[L3]: 请求失败 \(error.localizedDescription)")
                self.onState?(.failed(error.localizedDescription))
                return
            }

            guard let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["data"] as? [[String: Any]],
                  let first = list.first,
                  let lastText = first["last"] as? String,
                  let last = Double(lastText) else {
                return
            }

            // 该接口无涨跌幅字段，用开盘价自行计算
            let open = Double(first["open"] as? String ?? "") ?? 0
            let change = open > 0 ? (last - open) / open * 100 : 0

            self.onState?(.connected)
            self.onTick?(TickerSnapshot(
                symbol: first["market"] as? String ?? "BTCUSDT",
                displayName: "BTC / USDT  永续",
                last: last,
                changePercent: change,
                updatedAt: Date()
            ))
        }.resume()
    }
}
