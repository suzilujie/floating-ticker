import ActivityKit
import Combine
import Foundation

/// 实时活动（Live Activity）控制器：把行情显示在**锁屏**与**灵动岛**上。
///
/// **重要前提（务必知悉）**：Live Activity 的本地更新依赖 **App 进程存活** ——
/// 若 App 被 iOS 挂起，`update()` 根本没法调用，锁屏/灵动岛上的数字就会冻住。
/// 所以它是「保活」的**受益者**，而不是保活手段：保活成功，它才能实时刷新。
///
/// 两条平台限制（已处理）：
/// 1. **更新频率**：Apple 建议不超过 ~1 次/秒，更密会被节流甚至丢弃 → 本类做了节流
/// 2. **生命周期**：一条实时活动约 **8 小时**后被系统结束（锁屏再保留约 4 小时）
///    → 本类到达 7.5 小时会主动结束并重建，避免中途断掉
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<TickerActivityAttributes>?
    private var cancellable: AnyCancellable?
    private var lastUpdateAt: Date?
    private var recreateTimer: Timer?

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

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
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
        cancellable?.cancel()
        cancellable = nil
        lastUpdateAt = nil

        guard let activity = activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        LogCollector.shared.append("live: 实时活动已结束")
    }

    // MARK: - 更新

    private func update(price: Double, changePercent: Double) {
        guard let activity = activity else { return }

        // 节流：低于最小间隔的直接丢弃（系统本来也会节流，不如自己省一次序列化）
        if let last = lastUpdateAt, Date().timeIntervalSince(last) < Self.minUpdateInterval {
            return
        }
        lastUpdateAt = Date()

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
