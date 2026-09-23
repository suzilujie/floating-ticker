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

    /// 最近一次失败的**可执行诊断**（供界面直接显示，不必翻日志）。
    ///
    /// 为什么必须做这层映射：Apple 返回的 `reason` 是精确的，但对使用者没有指向性。
    /// 例如 `InvalidProviderToken` 的真实含义往往是
    /// 「粘的不是 APNs Auth Key，而是 App Store Connect API 密钥」——
    /// 两者都是 .p8、都有 10 位 Key ID，极易混淆，而本项目的 Ad Hoc 流水线用的正是后者。
    /// 只看 reason 根本想不到这一层，于是会反复怀疑"是不是哪里抄错了"。
    private(set) var lastFailureDiagnosis: String?

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
        // 显式声明"过期即弃"（0 = 立即投递、不存储、不重投）。
        // 对行情这种时效数据，「迟到的陈旧价」比「没有更新」更糟 ——
        // 若让 APNs 存储后在设备恢复时批量投递，锁屏上会短暂显示一个
        // 十几分钟前的价格，而且看不出它是旧的。下一个 tick 本来就会带来新价，
        // 所以这一条丢了也无所谓。
        request.setValue("0", forHTTPHeaderField: "apns-expiration")
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
                    let hint = Self.diagnose(status: status, body: body, topic: topic)
                    self.lastFailureDiagnosis = hint
                    LogCollector.shared.append(
                        "apns: ✗ 推送失败 \(priceText) status=\(status)"
                            + "｜err=\(error?.localizedDescription ?? "-")"
                            + "｜\(hint)"
                            + "｜body=\(body.prefix(120))"
                    )
                }
                completion(ok)
            }
        }.resume()
    }

    // MARK: - 失败诊断

    /// 把 APNs 的响应翻译成「下一步该做什么」。
    ///
    /// 判据是 Apple 返回的 `reason` 字段（不是 HTTP 状态码本身：
    /// 400 下面有十来种完全不同的原因，处置方式也完全不同）。
    private static func diagnose(status: Int, body: String, topic: String) -> String {
        if body.contains("InvalidProviderToken") || body.contains("MissingProviderToken") {
            return "APNs 不接受这份凭据。最常见的原因是**粘错了私钥**："
                + "开发者后台有两种 .p8 —— App Store Connect API 密钥（给 CI 上传用）"
                + "与 APNs Auth Key（给推送用），两者都是 .p8 且都有 10 位 Key ID。"
                + "请到 Keys 页新建一把、勾选 APNs 服务，把它的 Key ID 与私钥成对填这里。"
        }
        if body.contains("BadDeviceToken") {
            return "token 与推送环境不匹配：本 App 声明的是 aps-environment=production，"
                + "若这个包是用开发证书装的（Xcode 直跑 / 免费账号侧载），"
                + "拿到的是 sandbox token，需要改推 api.sandbox.push.apple.com。"
                + "先确认装的是 Ad Hoc / App Store 包。"
        }
        if body.contains("DeviceTokenNotForTopic") {
            return "topic 与 token 不配对：liveactivity 推送的 topic 必须是"
                + "「主 App bundle id」+.push-type.liveactivity。当前 topic=\(topic)。"
        }
        if body.contains("TopicDisallowed") {
            return "该 App ID 未开启推送能力：到开发者后台把 App ID 的 "
                + "Push Notifications 勾上，并重新生成描述文件。"
        }
        if body.contains("ExpiredProviderToken") {
            return "provider token 被判定为过期：检查设备时间是否准确（JWT 的 iat 依赖本机时钟）。"
        }
        if status == 410 {
            return "token 已失效（活动可能已被结束或重建过）。App 会重新取 token，稍后再试。"
        }
        if status == 429 {
            return "推送被限流。实时活动的推送预算有限，1 次/秒 的后台推送很可能已超预算 —— "
                + "确认 Info.plist 已声明 NSSupportsLiveActivitiesFrequentUpdates，"
                + "或降低后台推送频率。"
        }
        if status >= 500 {
            return "APNs 侧暂时不可用（\(status)），稍后重试即可。"
        }
        return "status=\(status)（未识别的失败原因，原始 body 见日志）"
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
