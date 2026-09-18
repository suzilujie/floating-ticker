import AudioToolbox
import Combine
import Foundation

/// 价格报警引擎。
///
/// 状态机（迟滞设计 —— 价格在阈值附近徘徊时不会反复轰炸）：
///
///     ARMED ──价格触及/穿越触发带──▶ ALERTING ──时长到──▶ COOLDOWN
///       ▲                                                   │
///       └──── 冷却到 && 价格已离开解除带（±容差×倍数）────────┘
///
/// 为什么必须做迟滞：若只用「进入容差带即报警」，价格在 69000 上下波动时
/// 会每几秒报一次，实际上等于不可用。故要求价格先真正离开（默认 ±100），
/// 才允许下一次触发。
///
/// 线程：所有状态变更都在主线程（行情回调经 DispatchQueue.main.async 归拢，
/// 计时器落在主 RunLoop）。
final class AlertEngine: ObservableObject {

    static let shared = AlertEngine()

    enum Phase: String {
        case armed = "已武装"
        case alerting = "报警中"
        case cooldown = "冷却中"
    }

    @Published private(set) var phase: Phase = .armed

    /// 渲染层据此切换报警视觉；帧泵据此提高帧率
    @Published private(set) var isAlerting = false

    @Published var config: AlertConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()

            // 触发参数一变就把状态机归零：否则用户刚改完目标价，却还要等上一轮冷却
            // 走完（最长 5 分钟）才可能触发，对"改完想立刻验证"的用法极不友好。
            if config.targetPrice != oldValue.targetPrice
                || config.tolerance != oldValue.tolerance
                || config.onlyDown != oldValue.onlyDown {
                resetState()
            }

            if !config.isEnabled, isAlerting {
                stopAlert()
            }
        }
    }

    /// 悬浮窗内的报警文案
    var alertTitle: String { "⚠ \(config.targetText) 已触及" }

    private let sound = AlertSoundPlayer()
    private var isStarted = false
    private var endTimer: Timer?
    private var lastPrice: Double?
    private var cooldownEndsAt: Date?
    /// 本次报警是否来自「试听」——试听结束不进冷却，不污染实盘状态
    private var isTest = false

    private init() {
        config = AlertConfig.load()
    }

    // MARK: - 生命周期

    /// 订阅行情。由主界面在启动时调用一次。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        LogCollector.shared.append(
            "alert: 引擎启动 目标 \(config.targetText)±\(Int(config.tolerance)) "
            + (config.onlyDown ? "（仅向下跌破）" : "（双向）")
        )

        TickerStore.shared.onSnapshot = { [weak self] snapshot in
            // 行情源可能在任意线程回调，状态机与音频播放统一归拢到主线程
            DispatchQueue.main.async {
                self?.handle(price: snapshot.last)
            }
        }
    }

    // MARK: - 状态机

    private func handle(price: Double) {
        // 先捕获上一价用于判定方向，再更新
        let previous = lastPrice
        defer { lastPrice = price }

        guard config.isEnabled else { return }

        switch phase {
        case .armed:
            guard let previous = previous else {
                // 首个行情快照就落在触发带内（例如刚启动、或用户把目标价设成现价
                // 用于验证）：无从判断方向，仍触发一次，避免漏报
                if inBand(price) { fire(isTest: false) }
                return
            }
            if crossed(previous: previous, current: price) {
                fire(isTest: false)
            }

        case .alerting:
            break   // 由 endTimer 负责结束

        case .cooldown:
            guard let endsAt = cooldownEndsAt, Date() >= endsAt else { return }
            // 时间到还不够：价格必须真的离开过，否则会在原地反复触发
            if !inResetBand(price) {
                cooldownEndsAt = nil
                phase = .armed
                LogCollector.shared.append("alert: 价格已离开解除带，重新武装")
            }
        }
    }

    /// 价格是否落在触发带内
    private func inBand(_ price: Double) -> Bool {
        abs(price - config.targetPrice) <= config.tolerance
    }

    /// 价格是否仍落在「解除冷却」范围内（比触发带更宽，构成迟滞）
    private func inResetBand(_ price: Double) -> Bool {
        abs(price - config.targetPrice) <= config.tolerance * config.resetMultiplier
    }

    /// 是否由带外触及 / 穿越触发带。
    ///
    /// 用「上一价在带外 && 当前价已进入或越过」判定，同时覆盖两种情形：
    /// 价格停在带内，以及直接跳穿整条带（如 69200 → 68800，中间没有任何一帧落在带内）。
    private func crossed(previous: Double, current: Double) -> Bool {
        let down = previous > config.upperBand && current <= config.upperBand
        let up = previous < config.lowerBand && current >= config.lowerBand
        return config.onlyDown ? down : (down || up)
    }

    // MARK: - 触发与结束

    private func fire(isTest: Bool) {
        self.isTest = isTest
        phase = .alerting
        isAlerting = true
        sound.start()
        vibrate()

        let current = lastPrice.map { String(format: "%.1f", $0) } ?? "--"
        LogCollector.shared.append(
            "alert: 触发报警（目标 \(config.targetText)，当前 \(current)，"
            + (isTest ? "试听" : "实盘") + "）"
        )

        endTimer?.invalidate()
        let duration = isTest ? Self.testDuration : config.duration
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func finish() {
        endTimer?.invalidate()
        endTimer = nil
        sound.stop()
        isAlerting = false

        if isTest {
            isTest = false
            phase = .armed
            LogCollector.shared.append("alert: 试听结束（不进冷却）")
        } else {
            phase = .cooldown
            cooldownEndsAt = Date().addingTimeInterval(config.cooldown)
            LogCollector.shared.append("alert: 报警结束，冷却 \(Int(config.cooldown)) 秒")
        }
    }

    /// 测试报警：立即演练一次「判定 → 响铃 + 红闪」的完整链路。
    ///
    /// 与真实触发的唯一差别是**不进冷却**（可反复测）。
    /// 判定仍走真实的 [`crossed(previous:current:)`]，只是喂给它一段构造走势：
    ///   上一价 = 触发带外上方，当前价 = 目标价 —— 即"价格从上方跌到目标"。
    /// 这样即便现价（约 76300）离目标（69000）还有 9.6%，也能立刻验证判定逻辑。
    func testFire() {
        guard !isAlerting else { return }
        guard config.isEnabled else {
            LogCollector.shared.append("alert: 测试未执行——报警当前为关闭状态")
            return
        }

        let simulatedPrevious = config.upperBand + config.tolerance
        guard crossed(previous: simulatedPrevious, current: config.targetPrice) else {
            LogCollector.shared.append("alert: 测试未触发——模拟走势不满足当前方向判据")
            return
        }

        LogCollector.shared.append("alert: 模拟触发（走真实判定路径，不进冷却）")
        fire(isTest: true)
    }

    /// 手动停止当前报警
    func stopAlert() {
        guard isAlerting else { return }
        finish()
    }

    /// 把状态机归零（回到已武装、清空冷却与上一价），用于参数变更后立即恢复可触发状态。
    ///
    /// 注意 `lastPrice = nil` 的用意：方向判定必须从头开始，否则会拿"改动前的旧价格"
    /// 去做跨带判断，产生误触发。副作用是——若改后的目标价正好落在当前价附近，
    /// 下一次行情推送即触发，这恰好方便验证。
    private func resetState() {
        endTimer?.invalidate()
        endTimer = nil
        sound.stop()
        isAlerting = false
        isTest = false
        cooldownEndsAt = nil
        lastPrice = nil
        phase = .armed
        LogCollector.shared.append("alert: 触发参数变更，状态机重置为已武装")
    }

    /// 试听时长（秒）：够听清即可，不必像实盘那样响 20 秒
    private static let testDuration: TimeInterval = 6

    private func vibrate() {
        // 注：后台/锁屏时 iOS 基本不允许 App 主动振动，此处仅在前台可靠生效。
        // 因此「辨识度」主要靠声音与视觉闪烁，震动只作补充。
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
