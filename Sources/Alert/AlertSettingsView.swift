import SwiftUI

/// 价格报警设置卡片（嵌入主界面的极简状态页）。
///
/// 刻意保留「试听报警」按钮：目标价通常离现价很远（如现价 76000、目标 69000），
/// 没有这个按钮就无法验证报警链路是否正常。
struct AlertSettingsView: View {

    @ObservedObject private var alert = AlertEngine.shared

    var body: some View {
        Section("价格报警") {
            Toggle("启用报警", isOn: $alert.config.isEnabled)

            HStack {
                Text("目标价")
                Spacer()
                TextField("69000", value: $alert.config.targetPrice, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 130)
            }

            HStack {
                Text("状态")
                Spacer()
                Text(alert.isAlerting ? "报警中" : alert.phase.rawValue)
                    .foregroundStyle(alert.isAlerting ? Color.red : Color.secondary)
            }
            .font(.subheadline)

            // 报警中优先给「停止」：这是最需要一眼可见、一点即中的按钮
            if alert.isAlerting {
                Button(role: .destructive) {
                    alert.stopAlert()
                } label: {
                    Text("停止报警")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button("试听报警（6 秒）") {
                    alert.testFire()
                }
            }

            // 规则说明默认收起：写全了有七八行，日常占掉大半屏；
            // 但它确实回答了"什么情况下才报"，所以留着、按需展开。
            DisclosureGroup("规则说明") {
                Text(ruleText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    /// 规则说明。用具体数字拼出来，避免用户读了还不知道"什么情况下才报"。
    ///
    /// 渲染的是**纯文本**（不是 Markdown），所以别用 `**加粗**` —— 会原样显示成星号。
    private var ruleText: String {
        let target = alert.config.targetText
        return """
        规则：价格「穿过」\(target)（向上或向下都算）时触发一次报警，并持续响；不会自动停止，需要按「停止」。

        每穿越一次触发一次；价格在 \(target) 同一侧持续波动不会重复触发。

        注意：只在"穿过那一刻"报警 —— 打开 App 时若价格已经在 \(target) 的某一侧，不会立刻报警。

        两个停止入口：① 本页/首页顶部的红色按钮 ② 浮窗上的暂停键。

        注意：直接关掉浮窗不会停止报警 —— 报警与灵动岛跟随 App 运行，关掉浮窗后仍在后台继续。

        试听：立即验证声音、红闪与震动，6 秒自动停，不影响实盘判定。
        """
    }
}

/// 信息行：左侧标题、右侧取值（与主界面同一样式）
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
