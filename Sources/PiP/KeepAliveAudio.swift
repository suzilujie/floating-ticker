import AVFoundation
import Foundation

/// 后台保活音频。
///
/// **为什么需要（真机实测驱动）**：
/// 锁屏后行情会停止更新，且解锁后长时间（>30 秒）不恢复 —— 这说明锁屏时
/// App 被 iOS **挂起**了：进程暂停 → 定时器停、网络停 → 自愈逻辑（看门狗、
/// 心跳、重连）根本没有机会运行。**PiP 会话本身不足以在锁屏态维持 App 运行。**
///
/// **原理**：iOS 对「正在播放音频」的 App 给予**持续后台执行权**。
/// 这里循环播放一段音频，使音频管线保持渲染 → audio session 保持 active →
/// App 不被挂起 → 锁屏期间行情继续更新。
///
/// **⚠️ 必须处理音频中断**：被其他 App 抢占 / 来电 / 闹钟 / Siri 都会让系统
/// **暂停**我们的播放，而 `AVAudioPlayer` 不会自己恢复 —— 保活一停，App 随即
/// 被挂起，行情、报警、灵动岛整条链路全停。详见 `ensurePlaying` 与
/// `observeInterruptionsIfNeeded`。
///
/// **关键实现细节：播"极低振幅的真实信号"，而不是"全 0 的数字静音"。**
/// 全 0 的 PCM 属于 **digital silence**，部分 iOS 版本会做静音检测，
/// 判定"没有实际输出"后把 audio session 挂起，保活随之失效。
/// 这里改用 **20Hz、振幅约 0.001（≈ -60dB）的正弦波**：
/// - **20Hz** 低于人耳听觉下限（20Hz~20kHz）→ 听不到
/// - **振幅 -60dB** 极轻 → 实际也听不到
/// - 但它是**真实信号（非全 0）** → 任何静音判定都不会认为"没在播"
final class KeepAliveAudio {

    static let shared = KeepAliveAudio()

    private var player: AVAudioPlayer?

    /// 用户是否**要求**保活开着 —— 与"此刻是否真的在播"是两件事。
    /// 中断恢复后据此判断要不要抢回会话（见 `observeInterruptionsIfNeeded`）。
    private var isWanted = false

    /// 中断监听只注册一次
    private var observingInterruptions = false

    private init() {}

    /// 是否正在保活（界面可据此显示状态）
    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        isWanted = true
        observeInterruptionsIfNeeded()
        ensurePlaying(reason: "启动")
    }

    func stop() {
        isWanted = false
        guard let player = player else { return }
        player.stop()
        self.player = nil
        LogCollector.shared.append("keepalive: 已停止")
    }

    // MARK: - 播放保障

    /// 确保"正在播放"。
    ///
    /// **这里是本次修复的核心**：原实现是 `guard player == nil else { return }` ——
    /// 音频被中断后 `player` 仍非 nil、但已经停止播放，于是**之后每一次 `start()`
    /// 都成了空操作，保活再也回不来**。现在改为：已存在但没在播 → 重新播。
    private func ensurePlaying(reason: String) {
        if player == nil {
            guard let data = Self.makeKeepAliveWAV(seconds: 1.0) else {
                LogCollector.shared.append("keepalive: 保活音轨生成失败")
                return
            }
            do {
                let created = try AVAudioPlayer(data: data)
                created.numberOfLoops = -1   // 无限循环
                created.volume = 1.0         // 音频数据本身已极轻，音量无需再压
                created.prepareToPlay()
                player = created
            } catch {
                LogCollector.shared.append("keepalive: 启动失败 \(error.localizedDescription)")
                return
            }
        }

        guard let player = player, !player.isPlaying else { return }
        player.currentTime = 0
        if player.play() {
            LogCollector.shared.append("keepalive: 保活音轨在播（\(reason)）")
        } else {
            LogCollector.shared.append("keepalive: play() 返回 false，保活可能失效")
        }
    }

    /// 监听音频中断。
    ///
    /// **为什么必须监听**：音频会话被其他 App 抢占，或来电 / 闹钟 / Siri 介入时，
    /// 系统会**暂停**我们的播放，而 `AVAudioPlayer` 不会自己恢复。
    /// 一旦保活音轨停了，App 在后台就会被系统挂起 —— 定时器与网络全停，
    /// 表现正是「锁屏后行情不再更新、报警也不响」。
    ///
    /// 关于"要不要无条件抢回会话"：这里选择**只要用户没主动关就恢复**。
    /// 依据是本 App 的产品前提就是"后台持续运行"（保活一断，行情 / 报警 / 灵动岛
    /// 整条链路全停），代价是会把音频会话从对方 App 手里拿回来。
    private func observeInterruptionsIfNeeded() {
        guard !observingInterruptions else { return }
        observingInterruptions = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                LogCollector.shared.append("keepalive: 音频被中断（保活暂停）")
            case .ended:
                guard self.isWanted else { return }
                // 必须先抢回会话再播：只调 play() 而不激活会话，
                // 声音与"正在播放"状态都不会真正生效
                try? AVAudioSession.sharedInstance().setActive(true)
                self.ensurePlaying(reason: "音频中断结束")
            @unknown default:
                break
            }
        }
    }

    // MARK: - 保活音轨合成

    /// 生成一段 16bit 单声道保活 WAV：44 字节标准头 + 20Hz 极低振幅正弦。
    ///
    /// 采样率取 8kHz：保活只需「有音频在渲染」，音质无关紧要，
    /// 低采样率能让缓冲区显著变小（1 秒仅 16KB）。
    private static func makeKeepAliveWAV(seconds: Double) -> Data? {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

        /// 20Hz —— 低于人耳听觉下限，听不到
        let frequency = 20.0
        /// 约 -60dB —— 极轻，实际听不到；但明显非零，不会被判为静音
        let amplitude = 0.001

        let sampleCount = Int(Double(sampleRate) * seconds)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataBytes = sampleCount * Int(channels) * bytesPerSample

        var d = Data()
        func put(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func putU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func putU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        put("RIFF")
        putU32(UInt32(36 + dataBytes))
        put("WAVE")
        put("fmt ")
        putU32(16)                                             // fmt 块长度
        putU16(1)                                              // 1 = PCM
        putU16(channels)
        putU32(sampleRate)
        putU32(sampleRate * UInt32(channels) * UInt32(bytesPerSample))   // 字节率
        putU16(channels * UInt16(bytesPerSample))              // 块对齐
        putU16(bitsPerSample)
        put("data")
        putU32(UInt32(dataBytes))

        // PCM 数据：20Hz 极低振幅正弦（非全 0）
        var pcm = Data(capacity: dataBytes)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let value = sin(2.0 * Double.pi * frequency * t) * amplitude
            let sample = Int16((value * 32767.0).rounded())
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        d.append(pcm)
        return d
    }
}
