import Foundation

/// APNs 凭据的**构建时注入**载体。
///
/// 仓库里保留的是这份**空占位**版本；CI 构建时会用仓库 Secrets
/// （`APNS_KEY_ID` / `APNS_KEY_P8`）**覆写**本文件，从而把凭据直接打进 App ——
/// 这样每次重装都不用再手动填写。
///
/// 未配置 Secrets 时本文件保持为空，App 自动退回「手动填写」模式。
///
/// ⚠️ 安全说明：注入后的凭据会随 ipa 分发，而本项目的 ipa 是公开下载的。
/// 单独拿到私钥**无法**向特定设备发推送（还需要该设备的活动 token，它不在包里），
/// 但请勿把填了真实凭据的本文件提交回仓库；若怀疑泄露，去开发者后台吊销密钥即可。
enum InjectedAPNsCredentials {
    static let keyID = ""
    static let p8Content = ""
}
