import AVKit
import SwiftUI
import UIKit

/// 主界面：极简状态页。
///
/// 产品形态是"打开即用"：应用启动后自动连接行情并自动开启悬浮窗，
/// 用户无需任何点击。本页只用于确认运行状态，并提供可折叠的诊断信息。
struct ContentView: View {

    /// 签名描述文件只需解析一次
    private static let profileExpiry: Date? = ProvisioningProfile.expirationDate()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    @ObservedObject private var market = TickerStore.shared
    @ObservedObject private var pip = PiPController.shared
    @ObservedObject private var alert = AlertEngine.shared
    @ObservedObject private var pipStyle = PiPStyle.shared

    /// 应用场景阶段：回到前台（含锁屏解锁）时用来触发一次数据新鲜度检查
    @Environment(\.scenePhase) private var scenePhase

    /// 防止 onAppear 重复触发启动
    @State private var didStart = false
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            List {
                // 报警中：置顶的停止入口。
                // 报警不会自动停止，而用户点浮窗回到 App 后第一眼就得能按到它，
                // 故放在列表最顶部（而不是埋在设置卡片里）。
                if alert.isAlerting {
                    Section {
                        Button(role: .destructive) {
                            alert.stopAlert()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bell.slash.fill")
                                Text("报警中 · 点此停止")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                // 主信息：实时价格
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(market.snapshot?.displayName ?? "BTC / USDT  永续")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(priceText)
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()

                        Text(changeText)
                            .font(.title3)
                            .monospacedDigit()
                            .foregroundStyle(changeColor)
                    }
                    .padding(.vertical, 6)
                }

                Section("运行状态") {
                    InfoRow(title: "行情", value: market.state.describe)
                    InfoRow(title: "数据源", value: market.activeSourceName)
                    // 悬浮窗：**整行即按钮** —— 点一下就把价格变成浮窗。
                    //
                    // 这里原先挤了三样东西（状态行 + 橙色警示 + 独立的"重新开启"按钮），
                    // 用户得先读懂再找准按钮才敢点；现在状态与操作合成一行，
                    // 点这一行的任何位置都算数。start() 自带 isActive 守卫，
                    // 已开启时点它不会有副作用。
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Button {
                            PiPController.shared.start()
                        } label: {
                            HStack {
                                Text("悬浮窗")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(pip.isActive ? "已开启" : (pip.isStarting ? "启动中…" : "点此开启"))
                                    .foregroundStyle(pip.isActive ? Color.secondary : Color.accentColor)
                            }
                            .font(.subheadline)
                            .contentShape(Rectangle())
                        }

                        // 只有"被系统静默忽略"这条路径才会出现这句话：
                        // 它没有任何错误回调，用户点了没反应却无从得知，所以把
                        // 可执行的下一步直接写出来（按 Home 键即自动转入浮窗）。
                        if !pip.isActive, let note = pip.lastStartNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        InfoRow(title: "悬浮窗", value: "本机不支持画中画")
                    }
                }

                // 价格报警：目标价、容差、状态与试听
                AlertSettingsView()

                // APNs 推送凭据与链路测试（锁屏更新）
                APNsSettingsView()

                // 数据源可达性：一键探测所有源，直观看清此刻哪个源能用
                SourceProbeView()

                // 诊断信息：默认折叠，不干扰主界面
                Section {
                    DisclosureGroup("诊断信息") {
                        InfoRow(title: "推送次数", value: "\(market.tickCount)")
                        InfoRow(title: "最后推送", value: lastTickText)
                        InfoRow(title: "构建提交", value: BuildInfo.commit)
                        InfoRow(title: "证书到期", value: expiryText)
                        InfoRow(title: "剩余时长", value: remainingText)

                        // 浮窗背景：实验性可调项（见 PiPStyle）。
                        // 画面逐帧重绘，切换后**立刻**在浮窗上生效，不用重开浮窗。
                        Picker("浮窗背景", selection: $pipStyle.background) {
                            Text("深色铺满").tag(PiPStyle.Background.dark)
                            Text("透明留白（实验）").tag(PiPStyle.Background.transparent)
                        }
                        .pickerStyle(.segmented)

                        Text(pipStyle.background == .dark
                             ? "整窗一块深色底（默认）"
                             : "仅内容区留底色、四周透明 —— 用于验证 PiP 是否支持透明透视")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Button("刷新日志") { refreshLog() }
                        Text(logText.isEmpty ? "暂无日志" : logText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("悬浮行情")
        }
        .onAppear {
            startIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // 回到前台（含锁屏解锁）立即核对数据新鲜度：后台期间连接可能已被静默掐断，
                // 这一步让用户一眼就看到最新价格，而不用干等看门狗的下一个周期。
                // 同时汇报后台期间的实时活动更新次数——排查「锁屏后冻住」的关键证据。
                LiveActivityController.shared.noteAppState(isActive: true)
                market.checkFreshness()
            case .background:
                LiveActivityController.shared.noteAppState(isActive: false)
            default:
                break
            }
        }
    }

    // MARK: - 自动启动

    /// 打开即用：同步启动画中画并连接行情，用户无需任何操作。
    ///
    /// 顺序说明：画中画启动必须在同步调用栈内发起（不得放入异步回调），
    /// 因此这里先开浮窗、再连行情——浮窗最初一两帧显示 "--" 属正常。
    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        LogCollector.shared.append("app: 自动启动（无用户交互）")
        PiPController.shared.start()
        market.start()
        AlertEngine.shared.start()
        // 灵动岛（实时活动）跟随 **App**，而不是跟随浮窗：
        // App 一启动就创建，只要它还在运行（在更新行情）就持续有效 ——
        // 一锁屏，系统就把这张卡显示在锁屏与灵动岛上，不需要浮窗在场。
        //
        // 为什么改掉"跟随浮窗"：浮窗是会被系统随时结束的（启动请求被静默忽略、
        // 被别的 App 的 PiP 顶掉、音频通道被抢占），而灵动岛不该跟着一起消失。
        LiveActivityController.shared.start()
        // 正在播放信息：锁屏媒体卡 / 控制中心 / 灵动岛展开态显示行情。
        // 走的是音乐类 App 后台更新元数据的官方通道（我们的音频保活本就占着这个槽位）
        NowPlayingTicker.shared.start()
        // 健康心跳：把「行情 / 报警检测 / 保活 / 实时活动」压成一行日志，
        // 供无调试器时远程排查（锁屏冻住这类问题全靠它取证）
        HealthHeartbeat.shared.start()
        refreshLog()
    }

    // MARK: - 计算属性

    private var priceText: String {
        guard let last = market.snapshot?.last else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: last)) ?? String(format: "%.1f", last)
    }

    private var changeText: String {
        guard let change = market.snapshot?.changePercent else { return "等待行情" }
        return String(format: "%+.2f%%", change)
    }

    private var changeColor: Color {
        guard let change = market.snapshot?.changePercent else { return .secondary }
        return change >= 0 ? .green : .red
    }

    private var lastTickText: String {
        guard let at = market.lastTickAt else { return "--" }
        return Self.timeFormatter.string(from: at)
    }

    private var expiryText: String {
        guard let expiry = Self.profileExpiry else { return "未读取到描述文件" }
        return Self.timeFormatter.string(from: expiry)
    }

    private var remainingText: String {
        guard let expiry = Self.profileExpiry else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        if days < 0 { return "已过期，需重新侧载" }
        return "\(days) 天"
    }

    private func refreshLog() {
        logText = LogCollector.shared.all.reversed().joined(separator: "\n")
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
