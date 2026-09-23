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
/// 1. 更新频率：前台 ~1 次/秒；后台/锁屏改走推送（推送本身仍受系统调度）
/// 2. 生命周期：约 8 小时被系统结束 → 7.5 小时主动重建
/// 3. 状态会变（ended / dismissed）→ 订阅 `activityStateUpdates` 自动重建
/// 4. 活动「超出进程」存活 → 启动时收编遗留活动，避免多实例
final class LiveActivityController {

    static let shared = LiveActivityController()

    /// APNs 推送 topic：`<主 App bundle id>.push-type.liveactivity`
    static var topic: String {
        (Bundle.main.bundleIdentifier ?? "com.xfish.floatingticker") + ".push-type.liveactivity"
    }

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

    /// 后台/锁屏期间的更新计数（取证用）
    private var backgroundUpdateCount = 0
    /// 活动非 active 时只记一次日志，避免每秒刷屏
    private var didLogInactive = false

    private static let foregroundUpdateInterval: TimeInterval = 1.0
    private static let backgroundUpdateInterval: TimeInterval = 1.0
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

        // 先把「超出进程存活」的遗留活动收编/清理掉，避免多实例并存
        if let adopted = adoptExistingActivity() {
            attach(to: adopted, reused: true)
            return
        }

        let attributes = TickerActivityAttributes(symbol: "BTC / USDT  永续")
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

        guard let old = old else { return }
        Task { await old.end(nil, dismissalPolicy: .immediate) }
        LogCollector.shared.append("live: 实时活动已结束")
    }

    // MARK: - 显示时机（灵动岛只在锁屏 / 后台出现）

    /// 即将离开前台时调用（scenePhase 变为 inactive），创建实时活动。
    ///
    /// **为什么必须在这一刻创建**：iOS 只允许 App 在**前台**启动实时活动；
    /// 真正进入后台后再 `request` 会失败。所以必须趁「还剩前台身份」时建好，
    /// 锁屏后锁屏界面才有这条活动。见 ContentView 的 scenePhase 处理。
    ///
    /// 前提：浮窗必须开着 —— 浮窗是后台运行的唯一依据，没浮窗时锁屏也不会更新，
    /// 建了只会显示一个冻住的价格，不如不建。
    func showForBackground() {
        guard PiPController.shared.isActive else {
            LogCollector.shared.append("live: 浮窗未开启，跳过创建实时活动（锁屏不会有灵动岛）")
            return
        }
        start()
    }

    /// 回到前台（解锁 / 切回 App）时调用：销毁实时活动，实现「灵动岛只在锁屏出现」。
    func hideForForeground() {
        guard activity != nil else { return }
        LogCollector.shared.append("live: 回到前台 → 销毁实时活动（灵动岛只保留在锁屏）")
        stop()
    }

    /// App 前后台切换时由界面调用：作为取证日志的时间锚点。
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
        didLogInactive = false
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
        return "\(base) / token=\(tok) / 推送成\(APNsPusher.shared.sentCount)败\(APNsPusher.shared.failedCount)"
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
            // 后台/锁屏：走 APNs 推送（系统采用推送；本地 write 在此态不被采用）。
            // 每次推送的结果在 APNsPusher 里记一行（成功/失败都记）。
            APNsPusher.shared.pushUpdate(state, token: token, topic: Self.topic) { _ in }
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
            await MainActor.run { self?.start() }
        }
    }
}
