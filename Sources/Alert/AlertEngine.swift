import AVFoundation
import AudioToolbox
import Combine
import Foundation
import UIKit

/// 价格报警引擎。
///
/// **状态机（2026-09-21 简化为「状态式」判定，不再用容差/穿越/冷却）**：
///
///     ARMED ──价格进入触发侧（默认：低于目标价）──▶ ALERTING
///       ▲                                            │
///       │                                    ┌───────┴────────┐
///       │                          价格回到另一侧          用户手动停止
///       │                                    │                │
///       └────────────────────────────────────┘                ▼
///       ▲                                                SILENCED
///       └────────────── 价格回到另一侧 ──────────────────────┘
///
/// 规则来源（用户明确要求）：
/// 1. **不要容差** —— 目标价就是硬阈值
/// 2. 价格在触发侧（默认"低于目标价"）**就一直报警**
/// 3. 价格回到另一侧 → **自动停止**
/// 4. 报警期间可手动停止；**手动停止后需价格先回到另一侧、再次进入触发侧**才重新报警
///    （否则关掉后下一笔行情会立刻又报，等于关不掉）
///
/// 线程：所有状态变更都在主线程（行情回调经 DispatchQueue.main.async 归拢，
/// 计时器落在主 RunLoop）。
final class AlertEngine: ObservableObject {

    static let shared = AlertEngine()

    enum Phase: String {
        case armed = "已武装"
        case alerting = "报警中"
        case silenced = "已静默"
    }

    @Published private(set) var phase: Phase = .armed

    /// 渲染层据此切换报警视觉；帧泵据此提高帧率
    @Published private(set) var isAlerting = false

    @Published var config: AlertConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()

            // 任何触发参数变更都把状态机归零：这样改完能立刻按新参数判定
            // （例如把目标价改到现价下方即可马上验证），
            // 也不会残留上一轮的报警/静默状态。
            resetState()
        }
    }

    /// 悬浮窗内的报警文案
    var alertTitle: String { "⚠ \(config.targetText) 已触及" }

    private let sound = AlertSoundPlayer()
    private var isStarted = false
    private var endTimer: Timer?
    private var hapticTimer: Timer?
    private var hapticTick = 0
    private var lastPrice: Double?
    /// 本次报警开始时间。用于识别浮窗暂停键的"误报停止"（见 PiPController）。
    private(set) var alertStartedAt: Date?
    /// 本次报警是否来自「试听」——试听是固定 6 秒的演练，不影响实盘判定状态
    private var isTest = false

    /// 数据源切换后是否需要「吞掉」下一笔快照。
    ///
    /// 原因：跨源基差（basis）会让价格在切换瞬间跳变几十美元。若把这笔跳变
    /// 当真实行情，可能凭空触发/停止一次报警。故切源后先吞一笔，只当基准价。
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
            "alert: 引擎启动 —— \(config.targetText) "
            + (config.onlyDown ? "以下就报警（回到上方自动停）" : "以上就报警（回到下方自动停）")
        )

        TickerStore.shared.onSnapshot = { [weak self] snapshot in
            // 行情源可能在任意线程回调，状态机与音频播放统一归拢到主线程
            DispatchQueue.main.async {
                self?.handle(price: snapshot.last)
            }
        }

        // 数据源切换时摘掉跨源跳变。
        // 为什么必须做：不同交易所有基差（实测 CoinEx 77879 / Gate 77935 / OKX 77947），
        // 切换源瞬间价格会跳变；若把这笔跳变当真实行情，会凭空触发或误停报警。
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
        // 数据源刚切换：这笔只作为新基准价，不参与状态判定（见 discardNextTick）
        if discardNextTick {
            discardNextTick = false
            lastPrice = price
            LogCollector.shared.append(
                "alert: 数据源切换后的首笔快照仅作基准价（\(String(format: "%.1f", price))）"
            )
            return
        }

        lastPrice = price

        guard config.isEnabled else { return }

        let onTriggerSide = config.isTriggeredSide(price)

        switch phase {
        case .armed:
            // 价格已进入触发侧 → 立即开始报警
            if onTriggerSide { fire(isTest: false) }

        case .alerting:
            // 价格回到另一侧 → 自动停止
            if !onTriggerSide {
                LogCollector.shared.append(
                    "alert: 价格已回到 \(config.targetText) \(config.safeSideText)，自动停止"
                )
                finish(autoStopped: true)
            }

        case .silenced:
            // 手动静默中：必须先回到另一侧才重新武装，
            // 否则"关掉后下一笔又报"，用户等于关不掉。
            if !onTriggerSide {
                phase = .armed
                LogCollector.shared.append(
                    "alert: 价格已回到 \(config.targetText) \(config.safeSideText)，重新武装"
                )
            }
        }
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
            "alert: 触发报警（\(config.targetText) \(config.safeSideText)的触发侧，"
            + "当前 \(current)，" + (isTest ? "试听" : "实盘") + "）"
        )

        endTimer?.invalidate()
        endTimer = nil

        // 实盘报警**不设自动停止时长**：只要价格还在触发侧就一直响，
        // 直到价格自己回到另一侧（自动停）或用户手动停。
        // 试听例外：固定 6 秒自动停，否则点一下就会一直叫。
        guard isTest else { return }

        let timer = Timer(timeInterval: Self.testDuration, repeats: false) { [weak self] _ in
            self?.finish(autoStopped: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    /// 结束报警。
    /// - Parameter autoStopped: true = 价格回到另一侧自动停（回到已武装）；
    ///   false = 用户手动停 / 试听到时（进入静默，等价格回到另一侧再武装）
    private func finish(autoStopped: Bool) {
        endTimer?.invalidate()
        endTimer = nil
        stopHaptics()
        sound.stop()
        isAlerting = false
        alertStartedAt = nil

        if isTest {
            isTest = false
            // 试听结束：按当前价格恢复状态。若此刻价格恰在触发侧，
            // 不能直接回到「已武装」（否则下一笔就立刻真报），故转为静默等它先离开。
            if let p = lastPrice, config.isTriggeredSide(p) {
                phase = .silenced
                LogCollector.shared.append("alert: 试听结束（当前价在触发侧，转静默，待价格离开后再武装）")
            } else {
                phase = .armed
                LogCollector.shared.append("alert: 试听结束")
            }
            return
        }

        if autoStopped {
            phase = .armed
        } else {
            phase = .silenced
            LogCollector.shared.append("alert: 已手动停止（价格先回到另一侧，再次进入触发侧才会再报）")
        }
    }

    /// 试听报警：立即演练一次「触发 → 响铃 + 红闪 + 震动」的完整输出链路。
    ///
    /// 与实盘触发的差别：固定 6 秒自动停，且不影响后续实盘判定状态。
    func testFire() {
        guard !isAlerting else { return }
        guard config.isEnabled else {
            LogCollector.shared.append("alert: 试听未执行——报警当前为关闭状态")
            return
        }

        LogCollector.shared.append("alert: 试听开始（6 秒后自动停）")
        fire(isTest: true)
    }

    /// 手动停止当前报警
    func stopAlert() {
        guard isAlerting else { return }
        finish(autoStopped: false)
    }

    /// 把状态机归零（回到已武装、清空上一价）。
    ///
    /// 用于参数变更后立即恢复可判定状态。注意 `lastPrice = nil` 的用意：
    /// 下一次行情会重新建立基准；若新目标价正好落在现价上方（触发侧），
    /// 下一笔即触发 —— 这正是"改成现价附近就能立刻验证"的原因。
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

    /// 试听时长（秒）：够听清即可
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
