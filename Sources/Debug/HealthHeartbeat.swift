import Foundation
import UIKit

/// 健康心跳：周期性把**整条行情链路**的状态压成 **一行**日志。
///
/// **为什么需要**：排查「锁屏后价格 / 灵动岛冻住」这类问题时，最关键的问题是
/// 「进程到底还在不在干活」。日志是 300 行环形缓冲，逐模块去翻很容易漏；
/// 一行心跳就能同时回答四件事：
/// 1. 行情还来不来（距上次行情多少秒）
/// 2. **报警还在不在检测**（这个窗口内评估了多少笔行情）
/// 3. 保活还活着吗（PiP / 保活音频）
/// 4. 实时活动在不在后台更新（活动状态 + 后台累计更新次数）
///
/// **频率设计**（避免刷屏把关键日志挤出 300 行缓冲）：
/// - **后台 / 锁屏**：每 10 秒一条 —— 正是要观察的窗口
/// - **前台**：每 60 秒一条 —— 只作时间锚点
final class HealthHeartbeat {

    static let shared = HealthHeartbeat()

    private var timer: Timer?
    private var tick = 0

    /// 上一次心跳时的报警评估计数，用于算「这个窗口内检测了多少笔」
    private var lastEvaluationCount = 0

    private static let interval: TimeInterval = 10

    /// 前台时每多少次心跳才输出一条（10 秒 × 6 = 60 秒）
    private static let foregroundEvery = 6

    private init() {}

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick += 1
            self.emitIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        LogCollector.shared.append("heartbeat: 健康心跳已启动（锁屏/后台每 10 秒，前台每 60 秒一条）")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tick = 0
        lastEvaluationCount = 0
    }

    private func emitIfDue() {
        let isBackground = UIApplication.shared.applicationState != .active
        // 前台只每 60 秒留一条锚点；后台（锁屏）则每次心跳都记 —— 那才是要看的窗口
        if !isBackground, tick % Self.foregroundEvery != 0 { return }
        LogCollector.shared.append(summary(isBackground: isBackground))
    }

    /// 把各模块状态压成一行。
    ///
    /// 关键字段解读：
    /// - `报警评估 N 笔/10s` —— 大于 0 就证明**报警引擎在锁屏期间仍在逐笔检测**；
    ///   若是 0，说明行情根本没送到引擎（问题在更上游）
    /// - `行情 Xs 前` —— 数据新鲜度；锁屏时若这个数持续变大，说明行情断了
    /// - `实时活动=活跃/后台更新 N 次` —— N 持续增长说明我们把更新推给了系统；
    ///   若这时锁屏数字仍不动，就是系统侧没用上（节流），而非我们没推
    private func summary(isBackground: Bool) -> String {
        let store = TickerStore.shared
        let alert = AlertEngine.shared

        let fresh: String
        if let at = store.lastTickAt {
            fresh = String(format: "%.1f", Date().timeIntervalSince(at))
        } else {
            fresh = "--"
        }

        let evaluated = alert.evaluationCount - lastEvaluationCount
        lastEvaluationCount = alert.evaluationCount

        let price = alert.lastPrice.map { String(format: "%.1f", $0) } ?? "--"
        let target = alert.config.targetText

        return "heartbeat: \(isBackground ? "锁屏/后台" : "前台") 第 \(tick) 次"
            + " · 行情 \(fresh)s 前 · 报警评估 \(evaluated) 笔/\(Int(Self.interval))s"
            + " · 报警=\(alert.phase.rawValue)（目标 \(target)，当前 \(price)）"
            + " · 数据源=\(store.activeSourceName)"
            + " · PiP=\(PiPController.shared.isActive ? "on" : "off")"
            + " · 保活=\(KeepAliveAudio.shared.isActive ? "on" : "off")"
            + " · 实时活动=\(LiveActivityController.shared.diagnosticState)"
    }
}
