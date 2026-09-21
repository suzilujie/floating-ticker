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

            Picker("触发条件", selection: $alert.config.onlyDown) {
                Text("跌破目标价").tag(true)
                Text("涨破目标价").tag(false)
            }
            .pickerStyle(.segmented)

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

            Text(ruleText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 规则说明。用具体数字与方向拼出来，避免用户读了还不知道"哪一侧才报"。
    private var ruleText: String {
        let dir = alert.config.onlyDown ? "低于" : "高于"
        let target = alert.config.targetText
        let back = alert.config.safeSideText
        return """
        规则：价格\(dir) \(target) 即开始报警并持续响；价格回到 \(target) \(back)则自动停止。

        报警期间可随时手动停止；手动停止后，需价格先回到 \(target) \(back)、再次\(dir)时才会重新报警（否则关掉后会立刻又响）。

        三个停止入口：① 本页/首页顶部的红色按钮 ② 浮窗上的暂停键 ③ 直接关掉浮窗（会连带停止）。

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
