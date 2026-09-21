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

    private init() {}

    /// 是否正在保活（界面可据此显示状态）
    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else { return }

        guard let data = Self.makeKeepAliveWAV(seconds: 1.0) else {
            LogCollector.shared.append("keepalive: 保活音轨生成失败")
            return
        }

        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1      // 无限循环
            player.volume = 1.0            // 音频数据本身已极轻，音量无需再压
            player.prepareToPlay()
            player.play()
            self.player = player
            LogCollector.shared.append("keepalive: 保活音轨已启动（20Hz 极低振幅，锁屏保活）")
        } catch {
            LogCollector.shared.append("keepalive: 启动失败 \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let player = player else { return }
        player.stop()
        self.player = nil
        LogCollector.shared.append("keepalive: 已停止")
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
