import Foundation

/// 数据源可达性探测（Reachability Probe）。
///
/// **为什么不检测「是否开了 VPN」**（这是刻意的取舍，勿改回）：
///   1) TUN 模式 VPN（Shadowrocket / Surge / Clash 默认）不写系统代理键，
///      `CFNetworkCopySystemProxySettings()` 读不到；
///   2) 第三方 VPN 的连接状态跨 App 读不到（`NEVPNManager` 只能读本 App 自己的配置）；
///   3) 靠枚举网络接口找 `utun*` / `ppp*` 会误判 —— 系统的 iCloud 私密代理、
///      Wi-Fi Calling 同样会创建 utun 接口（已有公开 issue 证实此类 false positive）；
///   4) 最关键的是「状态 ≠ 能力」：挂了代理但分流规则把目标域名走直连，照样不通；
///      反过来某些运营商 / 内网环境能直连，却没有任何 VPN 标志。
///
/// 故这里**直接验证目标端点此刻是否可达** —— 依据是事实而非推断。
/// 结论：**是否需要代理由网络环境决定，App 只认「此刻通不通」**，
/// 因此「不管有没有开 VPN，只要 OKX 可达就用 OKX」这条策略天然成立。
enum SourceProbe {

    // MARK: - 探测结果

    /// 单个数据源的可达性结果（界面直接展示）
    struct ProbeResult: Identifiable {
        let id = UUID()
        let name: String
        let isReachable: Bool
        let latencyMs: Int
        let detail: String
    }

    /// 探测目标：一个数据源端点
    struct Target {
        let name: String
        let url: URL
        /// WebSocket 端点需要用 ping/pong 往返验证，不能只看 TCP 是否建连
        let isWebSocket: Bool
    }

    /// 全部待探测源（供「数据源可达性」面板展示）。顺序即界面显示顺序。
    ///
    /// 只列**当前真正在用的两个源**：行情已改为「OKX + Binance 双源竞速 REST 轮询」
    /// （见 `RacingFuturesRestSource`）。旧版列出的 WS 与 Gate / CoinEx 端点已全部弃用，
    /// 继续留在面板里只会把排查方向带偏。
    static let targets: [Target] = [
        Target(name: "OKX 永续 REST",
               url: URL(string: "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP")!,
               isWebSocket: false),
        Target(name: "Binance 永续 REST",
               url: URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=BTCUSDT")!,
               isWebSocket: false)
    ]

    /// 探测超时 3 秒。
    ///
    /// 取值理由：代理链路的首次 TLS 握手可能偏慢（实测 OKX WS 经代理 924ms、
    /// REST 约 1.5s），但超过 3 秒才有响应的话，作为实时行情源也已没有意义。
    private static let timeout: TimeInterval = 3.0

    // MARK: - 全量探测（界面用）

    /// 并发探测所有目标，全部结束后在主线程一次性回调（结果按 `targets` 顺序）。
    ///
    /// 并发而非串行：串行最坏要等 5 × 3s = 15s，用户无法接受；
    /// 并发下总耗时约等于最慢的那个源（≈3s）。
    static func probeAll(completion: @escaping ([ProbeResult]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var byName: [String: ProbeResult] = [:]

        for target in targets {
            group.enter()
            probe(target) { result in
                lock.lock()
                byName[result.name] = result
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // 按 targets 顺序还原，避免并发导致的顺序随机
            completion(targets.compactMap { byName[$0.name] })
        }
    }

    private static func probe(_ target: Target, completion: @escaping (ProbeResult) -> Void) {
        if target.isWebSocket {
            probeWebSocket(target, completion: completion)
        } else {
            probeREST(target, completion: completion)
        }
    }

    // MARK: - REST 探测

    private static func probeREST(_ target: Target, completion: @escaping (ProbeResult) -> Void) {
        var request = URLRequest(url: target.url)
        request.timeoutInterval = timeout
        // 必须反映「此刻」的网络状况，不能被任何缓存结果掩盖
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let started = Date()

        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            if let error = error {
                completion(ProbeResult(name: target.name, isReachable: false, latencyMs: elapsed,
                                       detail: "请求失败：\(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(ProbeResult(name: target.name, isReachable: false, latencyMs: elapsed,
                                       detail: "无 HTTP 响应"))
                return
            }
            guard http.statusCode == 200 else {
                completion(ProbeResult(name: target.name, isReachable: false, latencyMs: elapsed,
                                       detail: "HTTP \(http.statusCode)"))
                return
            }
            completion(ProbeResult(name: target.name, isReachable: true, latencyMs: elapsed,
                                   detail: "HTTP 200"))
        }.resume()
    }

    // MARK: - WebSocket 探测

    /// 用协议级 ping/pong 往返验证 WS 是否真的通。
    ///
    /// 为什么不只看「能否建立连接」：被中间设备劫持 / 出口网关拦截时，
    /// TCP 握手可能"成功"，但数据根本无法往返。ping/pong 往返才算真通。
    private static func probeWebSocket(_ target: Target, completion: @escaping (ProbeResult) -> Void) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: target.url)
        let started = Date()
        let once = Once()

        /// 只允许完成一次（ping 结果与超时兜底会竞争）
        func finish(_ ok: Bool, _ detail: String) {
            once.perform {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                completion(ProbeResult(name: target.name, isReachable: ok, latencyMs: elapsed, detail: detail))
            }
        }

        task.resume()
        task.sendPing { error in
            if let error = error {
                finish(false, "握手失败：\(error.localizedDescription)")
            } else {
                finish(true, "WebSocket 握手成功")
            }
        }

        // 超时兜底：URLSessionWebSocketTask 没有直接的超时参数，
        // ping 一直不回来时必须自己兜住，否则这一项会永远悬着。
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1.5) {
            finish(false, "超时无响应")
        }
    }

    /// 「只执行一次」的小工具：并发结果与超时兜底会竞争同一个完成回调。
    private final class Once {
        private let lock = NSLock()
        private var fired = false

        func perform(_ block: () -> Void) {
            lock.lock()
            if fired { lock.unlock(); return }
            fired = true
            lock.unlock()
            block()
        }
    }

    // 说明：原先这里还有一个 `probeOKX`（探测 OKX 永续 WS 端点，供 TickerStore
    // 决定源优先级用）。改用 REST 双源竞速后，源切换不再依赖探测，它已无用；
    // 而它探测的是已弃用的 WS 端点，留着只会误导 —— 故删除。
}
