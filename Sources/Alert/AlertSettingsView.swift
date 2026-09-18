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

            Stepper(value: $alert.config.tolerance, in: 1...1000, step: 10) {
                HStack {
                    Text("容差")
                    Spacer()
                    Text("±\(Int(alert.config.tolerance))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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

            Button("试听报警") {
                alert.testFire()
            }
            .disabled(alert.isAlerting)

            Text("验证触发逻辑：把目标价改成当前价附近（容差 ±50），价格穿过即可自动触发。")
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
