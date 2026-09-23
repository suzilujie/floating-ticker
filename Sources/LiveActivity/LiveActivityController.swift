import ActivityKit
import Combine
import Foundation
import UIKit

/// 实时活动（Live Activity）控制器：把行情显示在**锁屏**与**灵动岛**上。
///
/// **重要前提**：Live Activity 的本地更新依赖 App 进程存活；锁屏/后台时
/// 本地 `update()` 实测**不被系统采用**。因此本版引入 **APNs 推送**：
/// 后台/锁屏时由 App「自己给自己发推送」（见 `APNsPusher`），走系统专门为
/// 「App 挂起也要更新」设计的通道；前台仍用本地 `update()`（更快、无网络往返）。
///
/// 已处理的平台约束：
/// 1. 更新频率：前台 ~1 次/秒（本地）；后台/锁屏 ~1 次/2.5 秒（走推送，避开推送速率预算）
/// 2. 生命周期：约 8 小时被系统结束 → 7.5 小时主动重建
/// 3. 状态会变（ended / dismissed）→ 订阅 `activityStateUpdates` 自动重建
/// 4. 活动「超出进程」存活 → 启动时收编遗留活动，避免多实例
/// 5. 后台**不能** `Activity.request`（只能 update / end）→ 后台重建改走 push-to-start；
///    两条都走不通就挂起，等回到前台补建（见 `restore` / `pendingRebuild`）
final class LiveActivityController: ObservableObject {

    static let shared = LiveActivityController()

    /// APNs 推送 topic：`<主 App bundle id>.push-type.liveactivity`
    static var topic: String {
        (Bundle.main.bundleIdentifier ?? "com.xfish.floatingticker") + ".push-type.liveactivity"
    }

    /// 活动的静态属性（币对名）。`Activity.request` 与 push-to-start 必须用同一个值，
    /// 提成常量避免两处写歪。
    private static let symbol = "BTC / USDT  永续"

    /// 对外可见：当前**是否有一条活动存在**（供界面显示「显示中 / 已关闭」）。
    ///
    /// 注意它表示"活动存在"，不表示"系统此刻正把它画在灵动岛上" —— 后者只有系统知道。
    @Published private(set) var isShowing = false

    private var activity: Activity<TickerActivityAttributes>?
    private var cancellable: AnyCancellable?
    private var lastUpdateAt: Date?
    private var recreateTimer: Timer?

    /// 活动状态监听任务（见 observeActivityState）
    private var stateTask: Task<Void, Never>?
    /// 推送 token 监听任务（见 observePushToken）
    private var tokenTask: Task<Void, Never>?

    /// 当前活动的 APNs 推送 token（自推送用）
    private var pushToken: String?

    /// **push-to-start** token（iOS 17.2+）。它与"某条活动"无关，是 **App 级**的：
    /// 用它可以让系统在**我们不在前台**时创建一条实时活动。
    private var pushToStartToken: String?
    private var pushToStartTask: Task<Void, Never>?

    /// 后台需要重建、但当场做不到时置位（后台不能 `request`，push-to-start 也不可用），
    /// 等 App 回到前台再补一次。
    ///
    /// 没有它，重建请求会在后台**静默失败且永不重试** —— 那正是
    /// "划掉灵动岛之后它再也不出现、直到重启 App"的根因。
    private var pendingRebuild = false

    /// 「认领」巡检：push-to-start 是**系统**创建的活动，App 手上没有引用，
    /// 必须主动认领才能继续 update —— 否则卡片会出现，却立刻冻在初始值上。
    private var adoptTimer: Timer?

    /// 用户是否**手动关掉了**灵动岛（界面上的开关）。
    ///
    /// 关掉后不再自动恢复、也不认领，直到用户重新打开。这个标志位是必要的：
    /// `stop()` 里的 `end()` 是**异步**的，在那之后的几百毫秒内旧活动仍是
    /// `.active`，5 秒巡检可能抢在前面把它认领回来 —— 表现就是"关了又自己回来"。
    private var userDisabled = false

    /// 后台/锁屏期间的更新计数（取证用）
    private var backgroundUpdateCount = 0
    /// 活动非 active 时只记一次日志，避免每秒刷屏
    private var didLogInactive = false

    /// 前台更新间隔：跟随行情（约 1 秒/条）。本地 `update()` 无网络往返，越快越跟手。
    private static let foregroundUpdateInterval: TimeInterval = 1.0

    /// 后台 / 锁屏更新间隔。
    ///
    /// 后台走 APNs 自推送，而**推送本身有速率预算** —— 超了返回 429 `TooManyRequests`。
    /// 注意这与曾经踩过的 `TooManyProviderTokenUpdates` 是**两个不同的原因**：
    /// 后者是 provider token 换得太勤，前者是**推得太密**。
    ///
    /// 取 2.5 秒（0.4 次/秒）：相对 1 次/秒减半还多，给系统留出余量；
    /// 锁屏上仍是「几秒一跳」，视觉上跟得住。
    ///
    /// 判据：若日志出现 `apns: ✗ 推送失败 … TooManyRequests`，说明 2.5 秒仍偏密，
    /// 继续放宽到 3~5 秒即可 —— 这个值可以放心往下调，代价只是刷新变钝。
    private static let backgroundUpdateInterval: TimeInterval = 2.5

    private static let recreateAfter: TimeInterval = 7.5 * 3600

    private init() {}

    // MARK: - 生命周期

    /// 开启实时活动并订阅行情。由主界面在启动时调用一次。
    func start() {
        bootstrap()
        // 走到这里一律视为"用户要它开着"（界面开关 / 启动 / 自动恢复）
        userDisabled = false

        guard activity == nil else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            LogCollector.shared.append(
                "live: 系统未开启「实时活动」，跳过（设置 → 悬浮行情 → 实时活动）"
            )
            return
        }

        // 先把「超出进程存活」的遗留活动收编/清理掉，避免多实例并存
        if let adopted = adoptExistingActivity() {
            attach(to: adopted, reused: true)
            return
        }

        let attributes = TickerActivityAttributes(symbol: Self.symbol)
        let content = ActivityContent(
            state: TickerActivityAttributes.ContentState(
                price: 0, changePercent: 0, updatedAt: Date().timeIntervalSince1970
            ),
            staleDate: nil
        )

        // 优先带 pushType .token：拿推送 token，供后台/锁屏自推送。
        // 若因缺少 Push 能力等原因失败，退回纯本地更新，保证实时活动仍然可用。
        do {
            let requested = try Activity.request(
                attributes: attributes, content: content, pushType: .token
            )
            LogCollector.shared.append("live: 实时活动已启动（锁屏 + 灵动岛，pushType=token）")
            attach(to: requested, reused: false)
        } catch {
            LogCollector.shared.append(
                "live: pushType .token 启动失败（\(error.localizedDescription)），退回本地模式"
            )
            do {
                let requested = try Activity.request(
                    attributes: attributes, content: content, pushType: nil
                )
                LogCollector.shared.append("live: 实时活动已启动（锁屏 + 灵动岛，无推送）")
                attach(to: requested, reused: false)
            } catch {
                LogCollector.shared.append("live: 启动失败 \(error.localizedDescription)")
            }
        }
    }

    /// 结束实时活动并停止订阅
    func stop() {
        let old = activity
        detach()
        backgroundUpdateCount = 0
        // 用户主动关掉 → 清掉挂起的重建、并且**不再自动恢复/认领**
        // （否则回到前台又冒出来，或在 end 生效前被巡检认领回来）
        pendingRebuild = false
        userDisabled = true

        guard let old = old else { return }
        Task { await old.end(nil, dismissalPolicy: .immediate) }
        LogCollector.shared.append("live: 实时活动已结束")
    }

    /// App 前后台切换时由界面调用：作为取证日志的时间锚点。
    func noteAppState(isActive: Bool) {
        if isActive {
            LogCollector.shared.append("live: App 回到前台（后台期间共更新 \(backgroundUpdateCount) 次）")
            // 后台做不成的事，回到前台立刻补 —— 此刻 `Activity.request` 才是合法的。
            // 没有这一步，后台失败的重建会一直挂到用户重启 App。
            if pendingRebuild, activity == nil {
                pendingRebuild = false
                LogCollector.shared.append("live: 补执行后台期间挂起的重建（此时已在前台）")
                start()
            }
        } else {
            LogCollector.shared.append("live: App 进入后台/锁屏（开始统计后台更新次数）")
        }
        backgroundUpdateCount = 0
    }

    // MARK: - 收编遗留活动

    /// 收编/清理系统里遗留的实时活动，返回「应当继续使用」的那一条。
    private func adoptExistingActivity() -> Activity<TickerActivityAttributes>? {
        let all = Activity<TickerActivityAttributes>.activities
        guard !all.isEmpty else { return nil }

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

    /// 绑定一条活动：订阅行情、盯状态、监听推送 token、起重建定时器。新建与收编共用。
    private func attach(to activity: Activity<TickerActivityAttributes>, reused: Bool) {
        self.activity = activity
        isShowing = true
        didLogInactive = false
        lastUpdateAt = nil

        cancellable = TickerStore.shared.tickPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.update(price: snapshot.last, changePercent: snapshot.changePercent)
            }

        observeActivityState(activity)
        observePushToken(activity)

        recreateTimer?.invalidate()
        let timer = Timer(timeInterval: Self.recreateAfter, repeats: true) { [weak self] _ in
            self?.recreate()
        }
        RunLoop.main.add(timer, forMode: .common)
        recreateTimer = timer

        if reused, let snapshot = TickerStore.shared.snapshot {
            update(price: snapshot.last, changePercent: snapshot.changePercent)
        }
    }

    /// 清理订阅、定时器与引用（**不结束活动本身**）。
    private func detach() {
        recreateTimer?.invalidate()
        recreateTimer = nil
        stateTask?.cancel()
        stateTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        pushToken = nil
        cancellable?.cancel()
        cancellable = nil
        lastUpdateAt = nil
        activity = nil
        isShowing = false
        didLogInactive = false
    }

    // MARK: - push-to-start 与「认领」

    /// 只执行一次的准备工作：接 push-to-start token、起「认领」巡检。
    private func bootstrap() {
        observePushToStartToken()
        startAdoptWatchdog()
    }

    /// 监听 push-to-start token（iOS 17.2+）。
    ///
    /// 这个 token 与"某条活动"无关，是 **App 级**的。token 会轮换，故要持续订阅。
    /// 低于 17.2 的系统没有这个能力 —— 那后台就无法自动恢复，只能挂起到前台再补。
    private func observePushToStartToken() {
        guard pushToStartTask == nil else { return }

        guard #available(iOS 17.2, *) else {
            LogCollector.shared.append(
                "live: 系统低于 17.2，不支持 push-to-start（后台将无法自动恢复灵动岛）"
            )
            return
        }

        if let data = Activity<TickerActivityAttributes>.pushToStartToken {
            pushToStartToken = Self.hexToken(data)
            LogCollector.shared.append(
                "live: 已取得 push-to-start token（\(String(pushToStartToken!.prefix(8)))…）"
            )
        }

        pushToStartTask = Task { [weak self] in
            for await data in Activity<TickerActivityAttributes>.pushToStartTokenUpdates {
                await MainActor.run {
                    guard let self = self else { return }
                    self.pushToStartToken = Self.hexToken(data)
                    LogCollector.shared.append(
                        "live: push-to-start token 已更新（\(String(self.pushToStartToken!.prefix(8)))…）"
                    )
                }
            }
        }
    }

    /// 「认领」巡检：每 5 秒看一眼 —— 若我们手上没有活动、而系统里有一条活跃的
    /// （多半是 push-to-start 拉起来的），就认领它。
    ///
    /// 为什么必须有：push-to-start 由**系统**创建活动，App 手上没有引用 ——
    /// 不认领的话 `update()` 会因 `activity == nil` 直接返回，
    /// 卡片虽然出现了，却冻在初始值上，比不出现更迷惑。
    private func startAdoptWatchdog() {
        guard adoptTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.adoptActiveIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        adoptTimer = timer
    }

    private func adoptActiveIfNeeded() {
        guard activity == nil, !userDisabled else { return }

        let active = Activity<TickerActivityAttributes>.activities
            .filter { $0.activityState == .active }
        guard let candidate = active.max(by: { $0.content.state.updatedAt < $1.content.state.updatedAt })
        else { return }

        // 顺带收掉多余的，避免又出现多实例
        for extra in active where extra.id != candidate.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }

        LogCollector.shared.append("live: 认领一条系统内的活跃实时活动（多半由 push-to-start 拉起）")
        attach(to: candidate, reused: true)
    }

    // MARK: - 活动状态监听与自愈

    private func observeActivityState(_ activity: Activity<TickerActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    guard let self = self, self.activity === activity else { return }
                    LogCollector.shared.append("live: 活动状态 → \(Self.describe(state))")

                    switch state {
                    case .ended:
                        // 系统结束（含约 8 小时上限）：必须恢复
                        self.restore(reason: "活动被系统结束")
                    case .dismissed:
                        // 用户划掉。当前策略是**自动恢复**（锁屏上仍需要这张卡），
                        // 恢复同样受"后台不能 request"约束，所以走 restore 分流。
                        // 若要"划掉就不再出现"，把这里改成不处理即可。
                        self.restore(reason: "活动被划掉")
                    default:
                        break
                    }
                }
            }
        }
    }

    /// 需要把实时活动重新建起来时，统一走这里 —— **按前后台分流**。
    ///
    /// 关键约束：`Activity.request` 只能在 App **前台**调用（Apple 明文规定，
    /// 后台只能 update / end）。所以后台要重建只有 push-to-start 一条路；
    /// 两条都走不通就挂起，等回到前台再补（`pendingRebuild`）。
    private func restore(reason: String) {
        // 用户已手动关掉 → 不恢复。这道守卫是双保险：正常情况下 stop() 会 detach，
        // 状态回调也随之取消，这里本就不会被触发。
        guard !userDisabled else { return }

        detach()
        backgroundUpdateCount = 0

        guard UIApplication.shared.applicationState != .active else {
            start()              // 前台：直接 request
            return
        }

        // 后台：优先用 push-to-start，让**系统**替我们创建
        if let token = pushToStartToken, APNsPusher.shared.isReady,
           let snapshot = TickerStore.shared.snapshot {
            let state = TickerActivityAttributes.ContentState(
                price: snapshot.last,
                changePercent: snapshot.changePercent,
                updatedAt: Date().timeIntervalSince1970
            )
            LogCollector.shared.append("live: \(reason) → 后台用 push-to-start 拉起实时活动")
            APNsPusher.shared.pushStart(
                symbol: Self.symbol, state: state, token: token, topic: Self.topic
            ) { [weak self] ok in
                guard let self = self, !ok else { return }
                // 推不出去就挂起等前台 —— 否则这次恢复会**静默丢失**
                self.pendingRebuild = true
                LogCollector.shared.append("live: push-to-start 失败 → 挂起，等回到前台补建")
            }
            return
        }

        pendingRebuild = true
        LogCollector.shared.append(
            "live: \(reason) → 后台无法重建（push-to-start 不可用），挂起等回到前台补建"
        )
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

    /// 诊断汇总（供健康心跳使用）：活动状态、实例数、推送 token 与推送成败计数。
    var diagnosticState: String {
        let total = Activity<TickerActivityAttributes>.activities.count
        let base: String
        if let activity = activity {
            base = "\(Self.describe(activity.activityState)) / 后台更新 \(backgroundUpdateCount) 次 / 系统内共 \(total) 条"
        } else {
            base = "无活动（系统内残留 \(total) 条）"
        }
        let tok = pushToken != nil ? "有" : "无"
        let boot = pushToStartToken != nil ? "有" : "无"
        let pending = pendingRebuild ? " / 待补建" : ""
        return "\(base) / token=\(tok)（start-token=\(boot)）"
            + " / 推送成\(APNsPusher.shared.sentCount)败\(APNsPusher.shared.failedCount)\(pending)"
    }

    // MARK: - 推送 token

    /// 监听活动推送 token 的获取与轮换。
    ///
    /// token 可能晚于活动创建才就绪，故既要读一次 `activity.pushToken`，
    /// 也要持续订阅 `pushTokenUpdates`（token 会轮换）。
    private func observePushToken(_ activity: Activity<TickerActivityAttributes>) {
        tokenTask?.cancel()

        if let data = activity.pushToken {
            pushToken = Self.hexToken(data)
            LogCollector.shared.append("live: 已取得推送 token（\(String(pushToken!.prefix(8)))…）")
        }

        tokenTask = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                await MainActor.run {
                    guard let self = self else { return }
                    self.pushToken = Self.hexToken(data)
                    LogCollector.shared.append("live: 推送 token 已更新（\(String(self.pushToken!.prefix(8)))…）")
                }
            }
        }
    }

    private static func hexToken(_ data: Data) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - 更新

    private func update(price: Double, changePercent: Double) {
        guard let activity = activity else { return }

        // 只有 ended / dismissed 才算「终止」；.stale 仍可继续更新。
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

        let isBackground = UIApplication.shared.applicationState != .active
        let interval = isBackground ? Self.backgroundUpdateInterval : Self.foregroundUpdateInterval
        if let last = lastUpdateAt, Date().timeIntervalSince(last) < interval {
            return
        }
        lastUpdateAt = Date()

        if isBackground {
            backgroundUpdateCount += 1
        }

        let state = TickerActivityAttributes.ContentState(
            price: price, changePercent: changePercent, updatedAt: Date().timeIntervalSince1970
        )

        if isBackground, let token = pushToken, APNsPusher.shared.isReady {
            // 后台/锁屏：走 APNs 推送（系统采用推送；本地 write 在此态实测不被采用）。
            // 每次推送的结果在 APNsPusher 里记一行（成功/失败都记）。
            APNsPusher.shared.pushUpdate(state, token: token, topic: Self.topic) { ok in
                guard !ok else { return }
                // **推送失败时补一次本地更新作为兜底。**
                //
                // 理由有两层：
                //  1) 在 APNs 尚未打通（凭据/能力/环境任一环节不通）期间，
                //     这条兜底能让锁屏与灵动岛至少不至于完全停摆，而不是干等修复。
                //  2) 更重要：声明了 NSSupportsLiveActivitiesFrequentUpdates 之后，
                //     「后台本地更新不被采用」这条既有结论**需要重新验证** ——
                //     它很可能本来就是【更新预算耗尽】的表象，而不是后台本身的限制。
                //     若重测后确认后台本地更新可用，APNs 就降级为纯兜底，
                //     整条链路少一个外部依赖。
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            }
        } else {
            // 前台 / 无 token / 未配置凭据：本地更新，每次记一行便于排障
            LogCollector.shared.append("live: 本地更新 \(String(format: "%.1f", price))")
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }
    }

    // MARK: - 测试推送（诊断用）

    /// 当前推送 token（供界面显示）
    var pushTokenHex: String? { pushToken }

    /// 手动发一条测试推送，验证「密钥 / 能力 / 环境 / topic」全链路是否打通。
    func sendTestPush(completion: @escaping (Bool) -> Void) {
        guard let token = pushToken, let snapshot = TickerStore.shared.snapshot else {
            LogCollector.shared.append("apns: 无法测试推送——无 token 或行情")
            completion(false)
            return
        }
        let state = TickerActivityAttributes.ContentState(
            price: snapshot.last,
            changePercent: snapshot.changePercent,
            updatedAt: Date().timeIntervalSince1970
        )
        APNsPusher.shared.pushUpdate(state, token: token, topic: Self.topic) { ok in
            LogCollector.shared.append(ok ? "apns: 测试推送成功（HTTP 200）" : "apns: 测试推送失败")
            completion(ok)
        }
    }

    /// 结束旧活动并重新开始 —— 绕过「约 8 小时后被系统结束」的上限。
    ///
    /// 注意：必须**等结束完成**再新建，否则旧活动会短暂残留在 `Activity.activities`
    /// 里被 `adoptExistingActivity` 收编回来。
    private func recreate() {
        LogCollector.shared.append("live: 到达重建周期，重启实时活动")
        let old = activity
        detach()

        Task { [weak self] in
            if let old = old {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            // 走 restore 而不是 start：在后台时 request 是非法的，需要 push-to-start
            await MainActor.run { self?.restore(reason: "到达重建周期") }
        }
    }
}
