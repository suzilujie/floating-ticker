import Foundation

/// 读取 App 内置的签名描述文件（embedded.mobileprovision），
/// 用于在 App 内显示证书到期时间。
///
/// 背景：免费 Apple ID 侧载的证书只有 7 天有效期，过期后 App 无法启动。
/// 在 App 内直接显示剩余天数，可避免"某天突然打不开"的困惑。
enum ProvisioningProfile {

    /// 证书到期时间；读取失败（如未签名调试构建）时返回 nil
    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        // mobileprovision 是 CMS/PKCS7 容器，内部嵌了一段 XML plist。
        // 使用 isoLatin1 解码可保证字节与 Unicode 标量一一对应，不会丢失数据。
        guard let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else {
            return nil
        }

        let plistText = String(raw[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1) else { return nil }

        let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        )
        guard let dict = plist as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }
}
