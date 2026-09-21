import AVFoundation
import Foundation

/// 后台保活音频（静音循环）。
///
/// **为什么需要（真机实测驱动）**：
/// 锁屏后行情会停止更新，且解锁后长时间（>30 秒）不恢复 —— 这说明锁屏时
/// App 被 iOS **挂起**了：进程暂停 → 定时器停、网络停 → 自愈逻辑（看门狗、
/// 心跳、重连）根本没有机会运行。**PiP 会话本身不足以在锁屏态维持 App 运行。**
///
/// **原理**：iOS 对「正在播放音频」的 App 给予**持续后台执行权**。
/// 这里循环播放一段**完全静音**的 PCM，使音频管线保持渲染 →
/// audio session 保持 active → App 不被挂起 → 锁屏期间行情继续更新。
///
/// **一个关键实现细节**：用静音的「数据」（PCM 全 0）而不是把播放器音量设为 0。
/// 音量设为 0 时系统可能直接跳过渲染，保活就失效了；而播静音数据时
/// 渲染管线是真在跑的，只是输出刚好无声。
final class KeepAliveAudio {

    static let shared = KeepAliveAudio()

    private var player: AVAudioPlayer?

    private init() {}

    /// 是否正在保活（界面可据此显示状态）
    var isActive: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else { return }

        guard let data = Self.makeSilentWAV(seconds: 1.0) else {
            LogCollector.shared.append("keepalive: 静音轨生成失败")
            return
        }

        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1      // 无限循环
            player.volume = 1.0            // 音量正常 —— 但数据本身是静音
            player.prepareToPlay()
            player.play()
            self.player = player
            LogCollector.shared.append("keepalive: 静音轨已启动（锁屏保活）")
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

    // MARK: - 静音 WAV 合成

    /// 生成一段 16bit 单声道静音 WAV（44 字节标准头 + 全 0 PCM）。
    ///
    /// 采样率取 8kHz：保活只需「有音频在渲染」，音质无关紧要，
    /// 低采样率能显著减小缓冲区（1 秒仅 16KB）。
    private static func makeSilentWAV(seconds: Double) -> Data? {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

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
        d.append(Data(count: dataBytes))                       // 全 0 = 静音
        return d
    }
}
