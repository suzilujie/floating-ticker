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
/// 代价是启动时多一次请求（几 KB），收益是判定结果在任何网络形态下都成立。
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

    /// 全部待探测源。顺序即界面显示顺序，与 TickerStore 的源链对应。
    static let targets: [Target] = [
        Target(name: "Gate 永续 WS",
               url: URL(string: "wss://fx-ws.gateio.ws/v4/ws/usdt")!,
               isWebSocket: true),
        Target(name: "OKX 永续 WS",
               url: URL(string: "wss://ws.okx.com:8443/ws/v5/public")!,
               isWebSocket: true),
        Target(name: "Gate 永续 REST",
               url: URL(string: "https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=BTC_USDT")!,
               isWebSocket: false),
        Target(name: "CoinEx 永续 REST",
               url: URL(string: "https://api.coinex.com/v2/futures/ticker?market=BTCUSDT")!,
               isWebSocket: false),
        Target(name: "OKX REST",
               url: URL(string: "https://www.okx.com/api/v5/public/time")!,
               isWebSocket: false)
    ]

    /// 探测超时 3 秒。
    ///
    /// 取值理由：代理链路的首次 TLS 握手可能偏慢（实测 OKX REST 经代理约 1.5s），
    /// 但超过 3 秒才有响应的话，作为实时行情源也已没有意义。
    private static let timeout: TimeInterval = 3.0

    /// OKX 公共时间接口：无参数、响应体最小，是最轻量的可达性探针。
    private static let okxProbeURL = URL(string: "https://www.okx.com/api/v5/public/time")!

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

    // MARK: - OKX 单点探测（TickerStore 启动时用于决定是否把 OKX 提为首选源）

    /// 探测 OKX 是否可达。回调保证在主线程。
    ///
    /// 调用约束：仅在 `TickerStore.start()` 触发一次；探测结果由调用方决定是否采用。
    static func probeOKX(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: okxProbeURL)
        request.timeoutInterval = timeout
        // 必须反映"此刻"的网络状况，不能被任何缓存结果掩盖
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let startedAt = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let verdict = evaluate(data: data, response: response, error: error)
            LogCollector.shared.append(
                "probe: OKX \(verdict.isReachable ? "可达" : "不可达")"
                    + "（\(elapsed)ms，\(verdict.reason)）"
            )
            DispatchQueue.main.async { completion(verdict.isReachable) }
        }.resume()
    }

    /// 判定结论
    struct Verdict {
        let isReachable: Bool
        /// 判定依据（写入日志，便于真机诊断）
        let reason: String
    }

    /// 判定规则：无错误 + HTTP 200 + 业务码 `"0"`，三者缺一不可。
    ///
    /// 为什么必须校验业务码：被中间设备劫持或出口网关拦截时，常见
    /// 「HTTP 200 但响应体不是预期结构」，只看状态码会误判为可达。
    private static func evaluate(data: Data?, response: URLResponse?, error: Error?) -> Verdict {
        if let error = error {
            return Verdict(isReachable: false, reason: "请求失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            return Verdict(isReachable: false, reason: "无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            return Verdict(isReachable: false, reason: "HTTP \(http.statusCode)")
        }
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? String else {
            return Verdict(isReachable: false, reason: "响应体无法解析（疑似被劫持）")
        }
        guard code == "0" else {
            return Verdict(isReachable: false, reason: "业务码 \(code)")
        }
        return Verdict(isReachable: true, reason: "HTTP 200，业务码 0")
    }
}
