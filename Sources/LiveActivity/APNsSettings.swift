import Combine
import Foundation

/// APNs 推送凭据：由用户在 App 内手动填写，仅存本机（UserDefaults）。
///
/// **为什么手动填写而非打进安装包**：本仓库公开、且 `.ipa` 发布在 GitHub Pages 上可公开下载。
/// 若把 `.p8` 私钥打进包里，等于公开泄露（任何人拿到都能给你的 App 发推送）。
/// 手动粘贴到 App、只存本机，是最简单也最安全的做法。
///
/// ⚠️ 说明：UserDefaults 是明文存储（本机沙箱内），个人自用可接受；若日后要分发，应迁移 Keychain。
final class APNsSettings: ObservableObject {

    static let shared = APNsSettings()

    /// Team ID（账号级、非敏感；与 project.yml 的 DEVELOPMENT_TEAM 一致）
    static let teamID = "S2GX2R7LD5"

    @Published var keyID: String { didSet { save() } }
    @Published var p8Content: String { didSet { save() } }

    /// 是否已具备发送条件
    var isReady: Bool {
        !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p8Content.contains("PRIVATE KEY")
    }

    private static let keyIDKey = "apns.keyID.v1"
    private static let p8Key = "apns.p8.v1"

    private init() {
        keyID = UserDefaults.standard.string(forKey: Self.keyIDKey) ?? ""
        p8Content = UserDefaults.standard.string(forKey: Self.p8Key) ?? ""
    }

    private func save() {
        UserDefaults.standard.set(keyID, forKey: Self.keyIDKey)
        UserDefaults.standard.set(p8Content, forKey: Self.p8Key)
    }
}
