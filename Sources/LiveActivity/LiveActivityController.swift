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
/// 四条平台限制（已处理）：
/// 1. **更新频率**：Apple 建议不超过 ~1 次/秒，更密会被节流甚至丢弃 → 本类做了节流
/// 2. **生命周期**：一条实时活动约 **8 小时**后被系统结束（锁屏再保留约 4 小时）
///    → 本类到达 7.5 小时会主动结束并重建
/// 3. **状态会变**：活动可能被系统结束、被用户划掉。此时本地 `activity` 引用**不会失效**，
///    `update()` 会**静默变成空操作**（不报错、不恢复），表现为数字永久冻住。
///    → 订阅 `activityStateUpdates`，发现 ended / dismissed 自动重建（见 `observeActivityState`）
/// 4. **活动会「超出进程」存活（本版修复）**：实时活动**不随 App 进程结束而消失** ——
///    App 被系统回收、崩溃、或用户上滑杀进程时，已开启的活动仍留在锁屏 / 灵动岛上。
///    新进程拿不到旧活动的引用，若直接再 `request` 一条，就会**多实例并存**，
///    而旧实例**永远不会再被更新**（表现：几个数字里有的在动、有的冻住）。
///    → 启动时先「收编」：挑最近更新的一条继续用，其余全部结束（见 `adoptExistingActivity`）
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

    /// 前台更新间隔：实测/官方建议实时活动更新不超过 ~1 次/秒。
    /// 我们的行情约每秒一条，节流后正好每笔都更新；抖动时也不会连发。
    private static let foregroundUpdateInterval: TimeInterval = 1.0

    /// 后台 / 锁屏更新间隔（放宽到 15 秒）。
    ///
    /// **为什么必须放宽**：App 在后台时，ActivityKit 会对本地更新做节流，
    /// 按秒推送时系统往往在几秒后开始**丢弃**更新 —— 外部表现正是
    /// 「锁屏一会儿灵动岛就不动了」。Apple 给出的标准建议也是
    /// 「App 在后台时降低 Live Activity 的更新频率」。
    ///
    /// 放宽到 15 秒后，锁屏态从「冻住」变成「每 15 秒跳一次」：
    /// 精度下降，但**保持存活**。回到前台立即恢复 1 秒级。
    private static let backgroundUpdateInterval: TimeInterval = 15.0

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

        // 先把「超出进程存活」的遗留活动收编/清理掉，避免多实例并存（见类注释第 4 条）
        if let adopted = adoptExistingActivity() {
            attach(to: adopted, reused: true)
            return
        }

        let attributes = TickerActivityAttributes(symbol: "BTC / USDT  永续")
        let state = TickerActivityAttributes.ContentState(
            price: 0, changePercent: 0, updatedAt: Date()
        )

        do {
            let requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            LogCollector.shared.append("live: 实时活动已启动（锁屏 + 灵动岛）")
            attach(to: requested, reused: false)
        } catch {
            LogCollector.shared.append("live: 启动失败 \(error.localizedDescription)")
        }
    }

    /// 结束实时活动并停止订阅
    func stop() {
        let old = activity
        detach()
        backgroundUpdateCount = 0

        guard let old = old else { return }
        Task { await old.end(nil, dismissalPolicy: .immediate) }
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
        } else {
            LogCollector.shared.append("live: App 进入后台/锁屏（开始统计后台更新次数）")
        }
        backgroundUpdateCount = 0
    }

    // MARK: - 收编遗留活动

    /// 收编/清理系统里遗留的实时活动，返回「应当继续使用」的那一条。
    ///
    /// **为什么必须做**：实时活动**不随 App 进程结束而消失** —— App 被系统回收、
    /// 崩溃，或用户上滑杀掉进程时，已开启的活动仍会留在锁屏 / 灵动岛上（最长约 8 小时）。
    /// 新进程启动时拿不到旧活动的引用，若直接再 `request` 一条，就会出现**多实例并存**；
    /// 而旧实例**永远不会再被更新**，于是「几个数字里有的在动、有的冻住」。
    ///
    /// 策略：
    /// - 挑**最近更新**的一条继续用（收编而非重建，避免灵动岛闪烁）
    /// - 其余仍活跃的、以及所有已结束/被划掉的，全部结束清理
    private func adoptExistingActivity() -> Activity<TickerActivityAttributes>? {
        let all = Activity<TickerActivityAttributes>.activities
        guard !all.isEmpty else { return nil }

        // 已结束 / 被划掉的顺手清掉（对已结束的活动调用 end 是幂等的）
        for stale in all where stale.activityState != .active {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        let alive = all.filter { $0.activityState == .active }
        guard let keep = alive.max(by: { $0.content.state.updatedAt < $1.content.state.updatedAt }) else {
            LogCollector.shared.append("live: 系统内有 \(all.count) 条已失效的实时活动 → 清理后重建")
            return nil
        }

        for extra in alive where extra.id != keep.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }

        LogCollector.shared.append(
            "live: 系统内有 \(all.count) 条遗留实时活动 → 收编最新一条，结束其余 \(all.count - 1) 条（避免多实例）"
        )
        return keep
    }

    /// 绑定一条活动：订阅行情、盯状态、起重建定时器。新建与收编共用。
    private func attach(to activity: Activity<TickerActivityAttributes>, reused: Bool) {
        self.activity = activity
        didLogInactive = false
        lastUpdateAt = nil

        // 订阅行情多播（不影响报警引擎那条 onSnapshot 回调）
        cancellable = TickerStore.shared.tickPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.update(price: snapshot.last, changePercent: snapshot.changePercent)
            }

        // 盯住活动状态：被结束/划掉时自动重建（否则 update() 会静默失效）
        observeActivityState(activity)

        // 到期自动重建
        recreateTimer?.invalidate()
        let timer = Timer(timeInterval: Self.recreateAfter, repeats: true) { [weak self] _ in
            self?.recreate()
        }
        RunLoop.main.add(timer, forMode: .common)
        recreateTimer = timer

        // 收编场景下，卡片上还停在「上一个进程最后一次写入」的数字 —— 立即用当前行情刷一次，
        // 免得用户先看到一个刚从冻结里醒来的旧价。
        if reused, let snapshot = TickerStore.shared.snapshot {
            update(price: snapshot.last, changePercent: snapshot.changePercent)
        }
    }

    /// 清理订阅、定时器与引用（**不结束活动本身**）。
    ///
    /// 拆出来是因为两条路径都需要它但后续动作不同：
    /// - `stop()` 之后要 `end()` 掉活动
    /// - `recreate()` 之后要 `await end()` 再新建（顺序很重要，见其注释）
    /// - `rebuild()` 之后直接新建（活动已经死了，无需再 end）
    private func detach() {
        recreateTimer?.invalidate()
        recreateTimer = nil
        stateTask?.cancel()
        stateTask = nil
        cancellable?.cancel()
        cancellable = nil
        lastUpdateAt = nil
        activity = nil
        didLogInactive = false
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
    ///
    /// 此时活动已是 ended / dismissed 状态，`adoptExistingActivity` 会把它过滤掉，
    /// 因此这里直接新建即可（不会把刚死的活动收编回来）。
    private func rebuild() {
        detach()
        backgroundUpdateCount = 0
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

    /// 诊断汇总（供健康心跳使用）：活动状态 + 后台更新次数 + **系统内活动总数**。
    ///
    /// 「总数」为什么重要：**大于 1 就说明出现了多实例** —— 那些旧实例再也不会更新，
    /// 正是「灵动岛 / 锁屏上有几个数字、有的不动」的根因。
    var diagnosticState: String {
        let total = Activity<TickerActivityAttributes>.activities.count
        guard let activity = activity else { return "无活动（系统内残留 \(total) 条）" }
        return "\(Self.describe(activity.activityState)) / 后台更新 \(backgroundUpdateCount) 次 / 系统内共 \(total) 条"
    }

    // MARK: - 更新

    private func update(price: Double, changePercent: Double) {
        guard let activity = activity else { return }

        // 只有 ended / dismissed 才算「终止」。注意 .stale 只是系统的「内容过期标记」，
        // 活动仍然可以继续更新 —— 若把它也当作终止，我们就会**自己把推送停掉**，
        // 表现就是界面在该状态下永久冻住（日志里只留一行"暂停更新"）。
        let activityState = activity.activityState
        guard activityState == .active || activityState == .stale else {
            if !didLogInactive {
                didLogInactive = true
                LogCollector.shared.append(
                    "live: 活动状态为 \(Self.describe(activityState))，暂停更新（等待自动重建）"
                )
            }
            return
        }
        didLogInactive = false

        // 节流：前台跟随行情（约 1 秒/次），后台/锁屏放宽到 15 秒以避开系统节流
        let isBackground = UIApplication.shared.applicationState != .active
        let interval = isBackground ? Self.backgroundUpdateInterval : Self.foregroundUpdateInterval
        if let last = lastUpdateAt, Date().timeIntervalSince(last) < interval {
            return
        }
        lastUpdateAt = Date()

        // 取证：累计后台/锁屏期间的更新次数，由健康心跳每 10 秒汇总成一行输出。
        // 刻意不在这里单独打点 —— 心跳已经带出了这个计数，少一行噪音就能让
        // 300 行环形缓冲多装些关键日志。
        if isBackground {
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
    ///
    /// 注意：必须**等结束完成**再新建。`end()` 是异步的，若立刻请求新活动，
    /// 旧活动仍会短暂出现在 `Activity.activities` 里，可能被 `adoptExistingActivity`
    /// 当成「遗留活动」又收编回来 —— 那就等于没重建。
    private func recreate() {
        LogCollector.shared.append("live: 到达重建周期，重启实时活动")
        let old = activity
        detach()

        Task { [weak self] in
            if let old = old {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run { self?.start() }
        }
    }
}
