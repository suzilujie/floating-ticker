import SwiftUI

/// 数据源可达性面板：一键并发探测所有源，显示「是否可达 + 耗时 + 判定依据」。
///
/// 为什么做成界面而不只是写日志：本项目是无调试器环境，
/// 换网络（直连 / 挂代理）后想确认「此刻到底哪个源能用」时，翻滚动日志很费劲；
/// 一屏结果能立刻回答这个问题，也方便对比不同网络环境下的差异。
struct SourceProbeView: View {

    @StateObject private var model = SourceProbeModel()

    var body: some View {
        Section {
            if model.results.isEmpty {
                HStack {
                    Text(model.isProbing ? "检测中…" : "尚未检测")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isProbing { ProgressView() }
                }
            } else {
                ForEach(model.results) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isReachable ? .green : .red)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.subheadline)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(result.isReachable ? "\(result.latencyMs)ms" : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(result.isReachable ? .green : .secondary)
                    }
                }

                if model.isProbing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("检测中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                model.run()
            } label: {
                Text(model.isProbing ? "检测中…" : "重新检测")
            }
            .disabled(model.isProbing)
        } header: {
            Text("数据源可达性")
        } footer: {
            Text("WS 源以 ping/pong 往返验证，REST 源以 HTTP 200 验证；全部并发，约 3 秒出结果。")
        }
        .onAppear {
            // 首次进入该卡片时自动检测一次；之后由用户手动触发
            if model.results.isEmpty { model.run() }
        }
    }
}

/// 探测面板的状态与调度
final class SourceProbeModel: ObservableObject {

    @Published private(set) var results: [SourceProbe.ProbeResult] = []
    @Published private(set) var isProbing = false

    func run() {
        guard !isProbing else { return }
        isProbing = true
        // 刻意不清空旧结果：探测期间保留上一次结果，避免界面闪成空白

        SourceProbe.probeAll { [weak self] results in
            guard let self = self else { return }
            self.results = results
            self.isProbing = false

            // 汇总写一行日志，便于事后回看「某个网络环境下各源能否用」
            let reachable = results.filter { $0.isReachable }.count
            let summary = results
                .map { "\($0.name)=\($0.isReachable ? "\($0.latencyMs)ms" : "不可达")" }
                .joined(separator: ", ")
            LogCollector.shared.append("probe: 全量探测完成（\(reachable)/\(results.count) 可达）\(summary)")
        }
    }
}
