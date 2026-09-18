import SwiftUI

/// 价格报警设置卡片（嵌入主界面的极简状态页）。
///
/// 刻意保留「试听报警」按钮：目标价通常离现价很远（如现价 76300、目标 69000，
/// 相差近 10%），没有这个按钮就无法验证报警链路是否正常。
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

            // 容差刻意用输入框而非 Stepper：验证真实触发时需要临时放大到几百，
            // 用步进按钮点 30 次不可接受。
            HStack {
                Text("容差")
                Spacer()
                Text("±")
                    .foregroundStyle(.secondary)
                TextField("50", value: $alert.config.tolerance, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 110)
            }

            Picker("触发方向", selection: $alert.config.onlyDown) {
                Text("仅向下跌破").tag(true)
                Text("双向").tag(false)
            }
            .pickerStyle(.segmented)

            InfoRow(title: "报警时长", value: "\(Int(alert.config.duration)) 秒")
            InfoRow(title: "冷却", value: "\(Int(alert.config.cooldown / 60)) 分钟")

            HStack {
                Text("状态")
                Spacer()
                Text(alert.isAlerting ? "报警中" : alert.phase.rawValue)
                    .foregroundStyle(alert.isAlerting ? Color.red : Color.secondary)
            }
            .font(.subheadline)

            Button("测试报警（立即）") {
                alert.testFire()
            }
            .disabled(alert.isAlerting)

            Text("测试方法：① 点上方按钮 → 立刻验证声音与红闪（走真实判定逻辑，不进冷却，可反复测）；② 想验证真实行情触发 → 把容差改成 500、目标价改成当前价，下一笔行情（1~2 秒）即会触发，完整响 20 秒并进入 5 分钟冷却。测完记得把目标价改回 69000。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
