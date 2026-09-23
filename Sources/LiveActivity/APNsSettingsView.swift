import SwiftUI

/// APNs 推送凭据录入 + 链路测试。
///
/// 用于「第 1 步：验证链路通不通」：填入 Key ID 与 .p8 后点「发送测试推送」，
/// 若锁屏上的实时活动立即变化，说明密钥 / 能力 / 环境 / topic 全链路打通。
struct APNsSettingsView: View {

    @ObservedObject private var settings = APNsSettings.shared
    @State private var testResult = ""
    @State private var tokenPreview = ""

    /// 凭据区默认**收起**。两个理由：
    ///   ① 凭据现在随包注入（见 `settings.sourceDescription`），日常根本不用碰；
    ///   ② 展开时私钥是**明文**，不该长期摊在主界面上 —— 截图、录屏都会带上它。
    /// 就绪状态留在折叠标题上，一眼可见，不必展开。
    @State private var isExpanded = false

    var body: some View {
        Section("APNs 推送（锁屏更新）") {
            DisclosureGroup(isExpanded: $isExpanded) {
                credentialsAndTest
            } label: {
                HStack {
                    Text("凭据与链路测试")
                    Spacer()
                    Text(settings.isReady ? "已就绪" : "未配置")
                        .foregroundStyle(settings.isReady ? Color.secondary : Color.orange)
                }
                .font(.subheadline)
            }
        }
    }

    /// 折叠内容：凭据录入 + 链路测试。
    @ViewBuilder
    private var credentialsAndTest: some View {
        TextField("APNs Key ID（10 位）", text: $settings.keyID)
            .autocapitalization(.none)
            .disableAutocorrection(true)

        TextEditor(text: $settings.p8Content)
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 90)
            .overlay(alignment: .topLeading) {
                if settings.p8Content.isEmpty {
                    Text("粘贴 .p8 私钥全文（以 -----BEGIN PRIVATE KEY----- 开头）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

        Text("凭据来源：\(settings.sourceDescription)")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if settings.isReady {
            Button("发送测试推送") { runTest() }

            if !testResult.isEmpty {
                Text("上次测试：\(testResult)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 失败原因直接显示在界面上，而不是只写日志：
            // 点一次按钮就能看到"下一步该做什么"，否则没人会为了这个去翻日志。
            if let diagnosis = APNsPusher.shared.lastFailureDiagnosis {
                Text(diagnosis)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("设备 token：\(tokenPreview.isEmpty ? "点测试后显示" : tokenPreview)")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("填入 Key ID 与私钥后即可测试。私钥只存本机，不进仓库、不进安装包。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func runTest() {
        tokenPreview = LiveActivityController.shared.pushTokenHex
            .map { String($0.prefix(16)) + "…" } ?? "无 token"
        LiveActivityController.shared.sendTestPush { ok in
            testResult = ok ? "成功（HTTP 200）" : "失败（原因见下方）"
        }
    }
}
