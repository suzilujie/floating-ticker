import CryptoKit
import Foundation

/// APNs 推送发送器：把行情状态通过 Apple Push Notification service 推给本设备的实时活动。
///
/// **为什么需要**：锁屏 / 后台时，App 的本地 `Activity.update()` 不被系统采用（真机实测），
/// 而 APNs 推送是 Apple 专门为「App 挂起也要更新」设计的通道 —— 由系统直接处理，
/// **不依赖 App 进程存活**。这里让 App 在还活着时「自己给自己发推送」，
/// 从而绕过「本地写入不被采用」的限制，全程无需任何服务器。
///
/// 关键点：
/// - 签名用 ES256 JWT（Apple 要求的 provider token），私钥是用户手动粘贴进 App 的 .p8
/// - `apns-topic` 必须是 `<主 App bundle id>.push-type.liveactivity`
/// - Ad Hoc / App Store 分发走 **production** 环境（`api.push.apple.com`）
final class APNsPusher {

    static let shared = APNsPusher()

    /// 成功 / 失败计数（诊断用，供健康心跳展示）
    private(set) var sentCount = 0
    private(set) var failedCount = 0

    /// 是否具备发送条件（Key ID 与私钥都已配置）
    var isReady: Bool { APNsSettings.shared.isReady }

    private static let endpoint = "https://api.push.apple.com/3/device/"

    private init() {}

    /// 推送一条「更新实时活动」的请求。
    ///
    /// `topic`：`<主 App bundle id>.push-type.liveactivity`
    /// 完成回调在主线程；`ok == true` 表示 Apple 返回了 200（HTTP 200 只代表
    /// Apple 收下了请求，最终是否刷新界面仍由系统调度决定）。
    func pushUpdate(
        _ state: TickerActivityAttributes.ContentState,
        token: String,
        topic: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard isReady,
              let jwt = Self.makeJWT(),
              let payload = Self.makePayload(state),
              let url = URL(string: Self.endpoint + token) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.httpBody = payload

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let ok = (status == 200) && (error == nil)
                let priceText = String(format: "%.1f", state.price)
                if ok {
                    self.sentCount += 1
                    // 每次推送结果都记一行，便于完整还原锁屏期间的推送轨迹
                    LogCollector.shared.append("apns: ✓ 推送成功 \(priceText)")
                } else {
                    self.failedCount += 1
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    LogCollector.shared.append(
                        "apns: ✗ 推送失败 \(priceText) status=\(status) err=\(error?.localizedDescription ?? "-") \(body.prefix(80))"
                    )
                }
                completion(ok)
            }
        }.resume()
    }

    // MARK: - JWT 与负载

    /// 构造 provider token（ES256 JWT）：header.kid=KeyID，payload.iss=TeamID。
    private static func makeJWT() -> String? {
        let s = APNsSettings.shared
        let keyID = s.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyID.isEmpty, s.p8Content.contains("PRIVATE KEY") else { return nil }

        let header: [String: Any] = ["alg": "ES256", "kid": keyID]
        let payload: [String: Any] = ["iss": APNsSettings.teamID, "iat": Int(Date().timeIntervalSince1970)]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let headerB64 = headerData.base64URL()
        let payloadB64 = payloadData.base64URL()
        let signingInput = headerB64 + "." + payloadB64

        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: s.p8Content),
              let signature = try? key.signature(for: Data(signingInput.utf8)) else { return nil }

        return signingInput + "." + signature.rawRepresentation.base64URL()
    }

    /// 构造实时活动更新负载。
    ///
    /// `content-state` 的键与 `TickerActivityAttributes.ContentState` 完全一致
    /// （price / changePercent / updatedAt）。`updatedAt` 用 epoch 秒的 Double，
    /// 避免 `Date` 在 JSON 里的编码歧义（这是推送路径必须对齐的细节）。
    private static func makePayload(_ state: TickerActivityAttributes.ContentState) -> Data? {
        let aps: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "event": "update",
            "content-state": [
                "price": state.price,
                "changePercent": state.changePercent,
                "updatedAt": state.updatedAt
            ]
        ]
        let payload: [String: Any] = ["aps": aps]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}

private extension Data {
    /// base64url（JWT 用）：+/ 换成 -_，去掉末尾 =。
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
