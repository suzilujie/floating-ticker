import SwiftUI

/// 价格报警设置卡片（嵌入主界面的极简状态页）。
///
/// 刻意保留「试听报警」按钮：目标价通常离现价很远（如现价 76300、目标 69000，
/// 相差近 10%），没有这个按钮就无法验证报警链路是否正常。
struct AlertSettingsView: View {

    @ObservedObject private var alert = AlertEngine.shared

    /// 冷却用「分钟」呈现（模型内仍以秒存储，避免改动已有存档格式）
    private var cooldownMinutes: Binding<Double> {
        Binding(
            get: { alert.config.cooldown / 60 },
            set: { alert.config.cooldown = max(1, $0) * 60 }
        )
    }

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

            // 冷却用输入框：它是需要按行情波动节奏反复试的参数，
            // 且模型里存的是秒、界面用分钟，故用派生 Binding 转换（不改存档格式）
            HStack {
                Text("冷却")
                Spacer()
                TextField("1", value: cooldownMinutes, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 110)
                Text("分钟")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("状态")
                Spacer()
                Text(alert.isAlerting ? "报警中（直到你按停止）" : alert.phase.rawValue)
                    .foregroundStyle(alert.isAlerting ? Color.red : Color.secondary)
            }
            .font(.subheadline)

            // 报警中优先给「停止」，这是最需要一眼可见、一点即中的按钮
            if alert.isAlerting {
                Button(role: .destructive) {
                    alert.stopAlert()
                } label: {
                    Text("停止报警")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button("测试报警（立即）") {
                    alert.testFire()
                }
            }

            Text("实盘报警**不会自动停止**，一直响到按下「停止」为止；冷却时间从停止那一刻起算。三个停止入口：① 本页/首页顶部的红色按钮 ② 浮窗上的暂停键 ③ 直接关掉浮窗（会连带停止）。\n测试：点上方按钮立刻验证声音、红闪与震动（走真实判定逻辑，不进冷却，可反复测）；想验证真实行情触发，把容差改成 500、目标价改成当前价即可，测完记得改回 69000。")
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
