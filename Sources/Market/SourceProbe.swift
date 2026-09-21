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
///
/// 调用约束：仅在 `TickerStore.start()` 触发一次；探测结果由调用方决定是否采用。
enum SourceProbe {

    /// OKX 公共时间接口：无参数、响应体最小，是最轻量的可达性探针。
    ///
    /// 之所以不用行情接口：行情接口有频控（rate limit），响应体也大得多，
    /// 而"能否建立 TLS 并拿到业务响应"这一事实与具体接口无关。
    private static let okxProbeURL = URL(string: "https://www.okx.com/api/v5/public/time")!

    /// 探测超时 3 秒。
    ///
    /// 取值理由：代理链路的首次 TLS 握手可能偏慢（实测 OKX REST 经代理约 1.5s），
    /// 但超过 3 秒才有响应的话，作为实时行情源也已没有意义。
    private static let timeout: TimeInterval = 3.0

    /// 判定结论
    struct Verdict {
        let isReachable: Bool
        /// 判定依据（写入日志，便于真机诊断）
        let reason: String
    }

    /// 探测 OKX 是否可达。回调保证在主线程。
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
