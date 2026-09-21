import ActivityKit
import Combine
import Foundation
import UIKit

/// 实时活动（Live Activity）控制器：把行情显示在**锁屏**与**灵动岛**上。
///
/// **重要前提（务必知悉）**：Live Activity 的本地更新依赖 **App 进程存活** ——
/// 若 App 被 iOS 挂起，`update()` 根本没法调用，锁屏/灵动岛上的数字就会冻住。
/// 所以它是「保活」的**受益者**，而不是保活手段：保活成功，它才能实时刷新。
///
/// 三条平台限制（已处理）：
/// 1. **更新频率**：Apple 建议不超过 ~1 次/秒，更密会被节流甚至丢弃 → 本类做了节流
/// 2. **生命周期**：一条实时活动约 **8 小时**后被系统结束（锁屏再保留约 4 小时）
///    → 本类到达 7.5 小时会主动结束并重建，避免中途断掉
/// 3. **状态会变（本版新增）**：活动可能被系统结束、被用户划掉。此时本地 `activity`
///    引用**不会失效**，`update()` 会**静默变成空操作**（不报错、不恢复），
///    外部表现就是「锁屏/灵动岛上的数字永久冻住」。
///    → 本类订阅 `activityStateUpdates`，一旦发现 ended / dismissed 就**自动重建**
///      （见 `observeActivityState`），并留下日志。
///
/// 取证：后台/锁屏期间的更新次数持续累计（见 `backgroundUpdateCount`），
/// 由健康心跳（`HealthHeartbeat`）每 10 秒汇总成一行输出 —— 用来确证
/// 「锁屏时到底有没有在推」。真机排查这类问题时，这一条最关键：
/// 否则无法区分「App 没在更新」与「更新了但系统没用上」。
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<TickerActivityAttributes>?
    private var cancellable: AnyCancellable?
    private var lastUpdateAt: Date?
    private var recreateTimer: Timer?

    /// 活动状态监听任务（见 observeActivityState）
    private var stateTask: Task<Void, Never>?

    /// 后台/锁屏期间的更新计数（取证用）。
    /// 回到前台时清零并在日志里汇报总数 —— 这是「锁屏期间是否一直在推」的直接证据。
    private var backgroundUpdateCount = 0
    /// 活动非 active 时只记一次日志，避免每秒刷屏
    private var didLogInactive = false

    /// 更新节流：实测/官方建议实时活动更新不超过 ~1 次/秒。
    /// 我们的行情约每秒一条，节流后正好每笔都更新；抖动时也不会连发。
    private static let minUpdateInterval: TimeInterval = 1.0

    /// 重建周期：系统约 8 小时结束活动，这里提前到 7.5 小时重建，留安全余量。
    private static let recreateAfter: TimeInterval = 7.5 * 3600

    private init() {}

    // MARK: - 生命周期

    /// 开启实时活动并订阅行情。由主界面在启动时调用一次。
    func start() {
        guard activity == nil else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            LogCollector.shared.append(
                "live: 系统未开启「实时活动」，跳过（设置 → 悬浮行情 → 实时活动）"
            )
            return
        }

        let attributes = TickerActivityAttributes(symbol: "BTC / USDT  永续")
        let state = TickerActivityAttributes.ContentState(
            price: 0, changePercent: 0, updatedAt: Date()
        )

        let requested: Activity<TickerActivityAttributes>
        do {
            requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            activity = requested
            didLogInactive = false
            LogCollector.shared.append("live: 实时活动已启动（锁屏 + 灵动岛）")
        } catch {
            LogCollector.shared.append("live: 启动失败 \(error.localizedDescription)")
            return
        }

        // 订阅行情多播（不影响报警引擎那条 onSnapshot 回调）
        cancellable = TickerStore.shared.tickPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.update(price: snapshot.last, changePercent: snapshot.changePercent)
            }

        // 盯住活动状态：被结束/划掉时自动重建（否则 update() 会静默失效）
        observeActivityState(requested)

        // 到期自动重建
        let timer = Timer(timeInterval: Self.recreateAfter, repeats: true) { [weak self] _ in
            self?.recreate()
        }
        RunLoop.main.add(timer, forMode: .common)
        recreateTimer = timer
    }

    /// 结束实时活动并停止订阅
    func stop() {
        recreateTimer?.invalidate()
        recreateTimer = nil
        stateTask?.cancel()
        stateTask = nil
        cancellable?.cancel()
        cancellable = nil
        lastUpdateAt = nil
        backgroundUpdateCount = 0

        guard let activity = activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        LogCollector.shared.append("live: 实时活动已结束")
    }

    /// App 前后台切换时由界面调用：作为取证日志的时间锚点。
    ///
    /// 为什么要记：排查「锁屏后灵动岛冻住」时，必须先确定锁屏的**确切时刻**，
    /// 才能对齐日志。回到前台时汇报后台期间的更新总数，一眼就能看出
    /// 「锁屏期间到底有没有在推」。
    func noteAppState(isActive: Bool) {
        if isActive {
            LogCollector.shared.append("live: App 回到前台（后台期间共更新 \(backgroundUpdateCount) 次）")
            backgroundUpdateCount = 0
        } else {
            LogCollector.shared.append("live: App 进入后台/锁屏（开始统计后台更新次数）")
            backgroundUpdateCount = 0
        }
    }

    // MARK: - 活动状态监听与自愈

    /// 订阅活动状态变化。被系统结束或被用户划掉时，**本地引用不会失效**，
    /// `update()` 会静默失效 —— 所以必须主动重建，否则锁屏数字永久冻住。
    private func observeActivityState(_ activity: Activity<TickerActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    guard let self = self, self.activity === activity else { return }
                    LogCollector.shared.append("live: 活动状态 → \(Self.describe(state))")

                    switch state {
                    case .ended, .dismissed:
                        LogCollector.shared.append("live: 活动已结束/被划掉 → 自动重建")
                        self.rebuild()
                    default:
                        break
                    }
                }
            }
        }
    }

    /// 活动终止后重建：清理旧引用与订阅，重新走一遍 start()。
    private func rebuild() {
        recreateTimer?.invalidate()
        recreateTimer = nil
        stateTask?.cancel()
        stateTask = nil
        cancellable?.cancel()
        cancellable = nil
        lastUpdateAt = nil
        activity = nil
        didLogInactive = false
        start()
    }

    private static func describe(_ state: ActivityState) -> String {
        switch state {
        case .active: return "活跃"
        case .stale: return "已过期标记"
        case .ended: return "已结束"
        case .dismissed: return "被划掉"
        @unknown default: return "未知状态"
        }
    }

    /// 诊断汇总（供健康心跳使用）：活动状态 + 后台期间累计更新次数。
    var diagnosticState: String {
        guard let activity = activity else { return "无活动" }
        return "\(Self.describe(activity.activityState)) / 后台更新 \(backgroundUpdateCount) 次"
    }

    // MARK: - 更新

    private func update(price: Double, changePercent: Double) {
        guard let activity = activity else { return }

        // 活动不在 active 说明它已被系统结束/被用户划掉。此时 update() 是空操作，
        // 继续调用只是白费序列化 —— 记一次日志，剩下交给状态监听触发重建。
        let activityState = activity.activityState
        guard activityState == .active else {
            if !didLogInactive {
                didLogInactive = true
                LogCollector.shared.append(
                    "live: 活动状态为 \(Self.describe(activityState))，暂停更新（等待自动重建）"
                )
            }
            return
        }
        didLogInactive = false

        // 节流：低于最小间隔的直接丢弃（系统本来也会节流，不如自己省一次序列化）
        if let last = lastUpdateAt, Date().timeIntervalSince(last) < Self.minUpdateInterval {
            return
        }
        lastUpdateAt = Date()

        // 取证：累计后台/锁屏期间的更新次数，由健康心跳每 10 秒汇总成一行输出。
        // 刻意不在这里单独打点 —— 心跳已经带出了这个计数，少一行噪音就能让
        // 300 行环形缓冲多装些关键日志。
        if UIApplication.shared.applicationState != .active {
            backgroundUpdateCount += 1
        }

        let state = TickerActivityAttributes.ContentState(
            price: price, changePercent: changePercent, updatedAt: Date()
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// 结束旧活动并重新开始 —— 绕过「约 8 小时后被系统结束」的上限。
    private func recreate() {
        LogCollector.shared.append("live: 到达重建周期，重启实时活动")
        stop()
        start()
    }
}
