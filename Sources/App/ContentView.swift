import AVKit
import SwiftUI
import UIKit

/// M0 阶段的验证界面。
///
/// 目标不是产品功能，而是验证三件事：
/// 1. CI 构建 → 下载 ipa → 侧载安装 → 启动 这条链路是否打通
/// 2. 免费 Apple ID 侧载的 App 内，画中画能力是否可用（M1 的前提）
/// 3. 当前证书还剩多少天（免费证书 7 天过期，需要提前收到提示）
struct ContentView: View {

    /// 签名描述文件只需解析一次，避免每次界面刷新都读文件
    private static let profileExpiry: Date? = ProvisioningProfile.expirationDate()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private let processStart = Date()

    /// 画中画是否已启动（M1）
    @State private var pipRunning = false

    var body: some View {
        NavigationStack {
            List {
                Section("M0 构建验证") {
                    Text("Hello, FloatingTicker")
                        .font(.headline)
                    Text("看到此界面说明 CI 构建、侧载安装、启动三步均已打通。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("画中画能力（M1 前提）") {
                    InfoRow(
                        title: "PiP supported",
                        value: pipSupported ? "true" : "false"
                    )
                    Text(pipSupported
                         ? "系统支持画中画，M1 阶段可继续实现悬浮窗。"
                         : "系统不支持画中画：本方案需重新评估。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("画中画测试（M1）") {
                    if pipSupported {
                        Button(pipRunning ? "关闭悬浮窗" : "开启悬浮窗") {
                            if pipRunning {
                                PiPController.shared.stop()
                                pipRunning = false
                            } else {
                                PiPController.shared.start()
                                pipRunning = true
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Text("点击「开启悬浮窗」后切回桌面，应出现一个悬浮小窗。窗口右上角时钟每秒跳动，即代表「帧泵 → 渲染 → 画中画」全链路打通。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("本机不支持画中画，M1 无法进行，需重新评估方案。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("证书状态") {
                    InfoRow(title: "到期时间", value: expiryText)
                    InfoRow(title: "剩余时长", value: remainingText)
                    Text("免费 Apple ID 证书 7 天过期，到期后 App 无法启动，需重新侧载。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("运行环境") {
                    InfoRow(title: "设备", value: UIDevice.current.model)
                    InfoRow(title: "系统版本", value: UIDevice.current.systemVersion)
                    InfoRow(title: "App 版本", value: appVersion)
                    InfoRow(title: "本次启动", value: Self.dateFormatter.string(from: processStart))
                }
            }
            .navigationTitle("悬浮行情")
        }
    }

    // MARK: - 计算属性

    private var pipSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var expiryText: String {
        guard let expiry = Self.profileExpiry else { return "未读取到描述文件" }
        return Self.dateFormatter.string(from: expiry)
    }

    private var remainingText: String {
        guard let expiry = Self.profileExpiry else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        if days < 0 { return "已过期，需重新侧载" }
        return "\(days) 天"
    }
}

/// 信息行：左侧标题、右侧取值
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

#Preview {
    ContentView()
}
