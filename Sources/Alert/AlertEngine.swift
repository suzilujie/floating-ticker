import AVFoundation
import AudioToolbox
import Combine
import Foundation
import UIKit

/// 价格报警引擎。
///
/// **触发方式：穿越（crossing）—— 不分方向，穿一次报一次**
///
///     ARMED ──价格穿过目标价（向上或向下）──▶ ALERTING
///       ▲                                      │
///       └──────────── 用户手动按「停止」─────────┘
///
/// 规则（用户明确要求）：
/// 1. **不要容差** —— 目标价就是硬阈值
/// 2. **不分方向** —— 向上穿、向下穿都触发（所以界面上没有方向选项）
/// 3. **穿一次报一次** —— 每次穿越触发一次报警
/// 4. **不自动停** —— 一直响，直到用户手动按「停止」
///
/// 为什么"穿越式"天然不会轰炸：只有**真的穿过**（上一价在一侧、当前价到另一侧）
/// 才算数。价格在 69000 同一侧持续波动时，无论怎么动都不会重复触发。
///
/// ⚠️ 固有特性（务必知悉）：**打开 App 时价格若已经在 69000 的某一侧，不会立刻报警**
/// —— 因为没有发生穿越。若希望"启动时也检一遍"，需要另加规则。
///
/// 线程：所有状态变更都在主线程（行情回调经 DispatchQueue.main.async 归拢，
/// 计时器落在主 RunLoop）。
final class AlertEngine: ObservableObject {

    static let shared = AlertEngine()

    enum Phase: String {
        case armed = "已武装"
        case alerting = "报警中"
    }

    @Published private(set) var phase: Phase = .armed

    /// 渲染层据此切换报警视觉；帧泵据此提高帧率
    @Published private(set) var isAlerting = false

    @Published var config: AlertConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()

            // 任何触发参数变更都把状态机归零：改完立刻按新参数待命，
            // 也不会残留上一轮的报警状态。
            resetState()
        }
    }

    /// 悬浮窗内的报警文案（不分方向，故用"已穿越"）
    var alertTitle: String { "⚠ 已穿越 \(config.targetText)" }

    private let sound = AlertSoundPlayer()
    private var isStarted = false
    private var endTimer: Timer?
    private var hapticTimer: Timer?
    private var hapticTick = 0
    private var lastPrice: Double?
    /// 本次报警开始时间。用于识别浮窗暂停键的"误报停止"（见 PiPController）。
    private(set) var alertStartedAt: Date?
    /// 本次报警是否来自「试听」——试听是固定时长的演练，不影响实盘状态
    private var isTest = false

    /// 数据源切换后是否需要「吞掉」下一笔快照。
    ///
    /// 原因：跨源基差（basis）会让价格在切换瞬间跳变几十美元。若把这笔跳变
    /// 当真实行情，可能凭空触发一次误报。故切源后先吞一笔，只当基准价。
    private var discardNextTick = false

    private init() {
        config = AlertConfig.load()
    }

    // MARK: - 生命周期

    /// 订阅行情。由主界面在启动时调用一次。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        LogCollector.shared.append(
            "alert: 引擎启动 —— 价格穿过 \(config.targetText) 时报警（上下都报，响到手动停）"
        )

        TickerStore.shared.onSnapshot = { [weak self] snapshot in
            // 行情源可能在任意线程回调，状态机与音频播放统一归拢到主线程
            DispatchQueue.main.async {
                self?.handle(price: snapshot.last)
            }
        }

        // 数据源切换时摘掉跨源跳变。
        // 为什么必须做：不同交易所有基差（实测 CoinEx 77879 / Gate 77935 / OKX 77947），
        // 切换源瞬间价格会跳变；若把这笔跳变当真实行情，会凭空触发一次误报。
        TickerStore.shared.onSourceChanged = { [weak self] name in
            DispatchQueue.main.async {
                LogCollector.shared.append("alert: 数据源切换为 \(name)，下一笔快照仅作基准价")
                self?.discardNextTick = true
            }
        }

        observeAudioInterruptions()
    }

    /// 监听音频会话被抢占 / 恢复。
    ///
    /// 为什么必须监听：我们平时不发声，用户切去刷抖音/看视频时，音频会话会被
    /// 对方抢走并打断我们。若不做处理，报警时可能"出声失败且毫无提示"。
    /// 这里既写日志（便于真机诊断"刷抖音时报警能不能响"），
    /// 也在**报警中被抢占后**主动抢回会话并重新出声（平时则不打扰对方 App）。
    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                LogCollector.shared.append("audio: 会话被其他 App 抢占（如抖音开始播放）")
            case .ended:
                LogCollector.shared.append("audio: 会话可恢复")
                // 仅在报警中才抢回，避免平时平白打断对方 App 的播放
                guard self.isAlerting else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.sound.start()   // 幂等：重新出声
            @unknown default:
                break
            }
        }
    }

    // MARK: - 状态机

    private func handle(price: Double) {
        // 数据源刚切换：这笔只作为新基准价，不参与穿越判定（见 discardNextTick）
        if discardNextTick {
            discardNextTick = false
            lastPrice = price
            LogCollector.shared.append(
                "alert: 数据源切换后的首笔快照仅作基准价（\(String(format: "%.1f", price))）"
            )
            return
        }

        let previous = lastPrice
        lastPrice = price

        guard config.isEnabled else { return }

        switch phase {
        case .armed:
            // 只在「穿过」时触发：上一价在阈值一侧、当前价到另一侧。
            // 首笔行情没有上一价可比较 → 不触发（穿越式不认"一开始就在某一侧"）。
            guard let previous = previous else { return }
            if crossed(previous: previous, current: price) {
                fire(isTest: false)
            }

        case .alerting:
            // 报警中：不自动停，也不重复触发（已经在响了），等用户按「停止」。
            // 穿越式下"价格在同侧波动"不会产生新穿越，所以这里什么都不用做。
            break
        }
    }

    /// 是否**穿过**目标价（不区分方向）。
    ///
    /// 判据 = 上一价与当前价分别位于目标价的两侧：
    /// - 向下：上一价 ≥ 目标价 且 当前价 < 目标价
    /// - 向上：上一价 ≤ 目标价 且 当前价 > 目标价
    ///
    /// 用「两侧位置」而不是「差值符号」，能正确覆盖两种情形：
    /// - **跳穿**：上一价 69200、当前价 68800（中间没有任何一帧落在阈值上）也算
    /// - **动了但没穿**：70000 → 69500 虽然跌了 500，但没跨过目标价，**不算**
    private func crossed(previous: Double, current: Double) -> Bool {
        let down = previous >= config.targetPrice && current < config.targetPrice
        let up = previous <= config.targetPrice && current > config.targetPrice
        return down || up
    }

    // MARK: - 触发与结束

    private func fire(isTest: Bool) {
        self.isTest = isTest
        phase = .alerting
        isAlerting = true
        alertStartedAt = Date()
        sound.start()
        startHaptics()

        let current = lastPrice.map { String(format: "%.1f", $0) } ?? "--"
        LogCollector.shared.append(
            "alert: 穿越触发报警（目标 \(config.targetText)，当前 \(current)，"
            + (isTest ? "试听" : "实盘") + "）"
        )

        endTimer?.invalidate()
        endTimer = nil

        // **不设自动停止**：一直响，直到用户手动按「停止」。
        // 试听例外：固定时长自动停，否则点一下就会一直叫。
        guard isTest else {
            LogCollector.shared.append("alert: 将持续响铃与震动，直到用户按「停止」")
            return
        }

        let timer = Timer(timeInterval: Self.testDuration, repeats: false) { [weak self] _ in
            self?.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    /// 结束报警并回到「已武装」，等待下一次穿越。
    private func finish() {
        endTimer?.invalidate()
        endTimer = nil
        stopHaptics()
        sound.stop()
        isAlerting = false
        alertStartedAt = nil

        let wasTest = isTest
        isTest = false
        phase = .armed
        LogCollector.shared.append(wasTest ? "alert: 试听结束" : "alert: 已停止（等待下一次穿越）")
    }

    /// 试听报警：立即演练一次「触发 → 响铃 + 红闪 + 震动」的完整输出链路。
    ///
    /// 与实盘触发的差别：固定时长自动停；触发源是按钮而非行情，不影响后续实盘判定。
    func testFire() {
        guard !isAlerting else { return }
        guard config.isEnabled else {
            LogCollector.shared.append("alert: 试听未执行——报警当前为关闭状态")
            return
        }

        LogCollector.shared.append("alert: 试听开始（\(Int(Self.testDuration)) 秒后自动停）")
        fire(isTest: true)
    }

    /// 手动停止当前报警
    func stopAlert() {
        guard isAlerting else { return }
        finish()
    }

    /// 把状态机归零（回到已武装、清空上一价）。
    ///
    /// 用于参数变更后立即恢复待命状态。注意 `lastPrice = nil` 的用意：
    /// 下一次行情只用来重建基准价，**从再下一笔起**才能判定穿越 ——
    /// 也就是说，改完参数后需要价格真正再穿过一次才会报警
    /// （穿越式触发下不存在"改完立刻触发"，这是它的固有特性）。
    private func resetState() {
        endTimer?.invalidate()
        endTimer = nil
        stopHaptics()
        sound.stop()
        isAlerting = false
        isTest = false
        lastPrice = nil
        discardNextTick = false
        phase = .armed
        LogCollector.shared.append("alert: 触发参数变更，状态机重置")
    }

    /// 试听时长（秒）：够听清即可，不必像实盘那样响到用户手动停
    private static let testDuration: TimeInterval = 6

    /// 与警报音「嘀」的间隔一致：0.10 秒发声 + 0.07 秒间隔
    private static let hapticInterval: TimeInterval = 0.17

    /// 启动震动，节奏与警报音对齐：一秒内连震三下、随后静默，循环往复。
    ///
    /// ⚠️ 平台限制（务必知悉）：**iOS 基本不允许后台 App 主动震动**。
    /// - 前台（App 可见）：可靠生效 —— UIFeedbackGenerator 正常工作
    /// - 后台 / 锁屏：`UIFeedbackGenerator` 是空操作，`AudioServicesPlaySystemSound`
    ///   也常被系统忽略 —— 属"尽力而为"，不保证生效
    ///
    /// 若要求在后台**一定**震动，唯一可靠途径是发一条本地通知（系统通知会震动），
    /// 代价是必然会弹横幅并带上系统提示音，iOS 不提供"只震不响"的通知。
    private func startHaptics() {
        stopHaptics()
        hapticTick = 0

        // 起手用最强的一下：系统级震动 + 警告触觉
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        let timer = Timer(timeInterval: Self.hapticInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 每 6 拍一轮：前 3 拍震（对应「嘀-嘀-嘀」），后 3 拍静默
            self.hapticTick = (self.hapticTick + 1) % 6
            if self.hapticTick < 3 {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hapticTimer = timer
    }

    private func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
    }
}
