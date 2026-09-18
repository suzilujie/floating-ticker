import Foundation

/// 构建指纹。
///
/// 本文件在本地编译时用下面的占位值；CI 构建前会被自动覆盖为
/// 真实的 commit SHA 与构建时间（见 .github/workflows/ios-build.yml）。
/// 目的：一眼确认手机上装的是哪一次构建，避免"装错版本"造成的误判。
enum BuildInfo {
    static let commit = "local"
    static let builtAt = "local"
}
