import AVFoundation
import Foundation

/// 报警音的合成与播放。
///
/// 为什么用代码合成，而不是放一个音频素材：
/// 1. 本项目的 ipa 由 GitHub Actions 构建，仓库不适合携带二进制音频素材；
/// 2. 合成音完全可控，能做出与任何手机自带通知音都不重样的音色 —— 这正是
///    「辨识度高」的关键：听到就知道是自己的报警，而不是微信来了。
///
/// 音色（已选定的方案 A：急促三连音）：
///   2200 Hz **方波**「嘀-嘀-嘀」，每声 0.10 秒、间隔 0.07 秒，三连后静默 0.55 秒，
///   整段约 1.06 秒并循环播放，直到报警结束。
///   用方波而非正弦波：方波谐波丰富、穿透力强，在嘈杂环境里更容易被听见。
final class AlertSoundPlayer {

    // MARK: - 可调音色参数（想换音色改这几个常量即可）
    private static let beepFrequency: Double = 2200
    private static let beepDuration: Double = 0.10
    private static let beepGap: Double = 0.07
    private static let beepCount = 3
    private static let tailSilence: Double = 0.55
    private static let sampleRate: Double = 44100
    /// 幅度：留一点余量避免削顶失真
    private static let amplitude: Double = 0.85

    private var player: AVAudioPlayer?

    /// 开始循环播放报警音（幂等：重复调用不会叠加播放）
    func start() {
        if player == nil {
            player = makePlayer()
        }
        guard let player = player else { return }
        guard !player.isPlaying else { return }
        player.currentTime = 0
        player.play()
    }

    /// 停止报警音
    func stop() {
        player?.stop()
    }

    // MARK: - 播放器构建

    private func makePlayer() -> AVAudioPlayer? {
        let wav = Self.makeWavData()
        guard let player = try? AVAudioPlayer(data: wav) else {
            LogCollector.shared.append("alert: 报警音播放器创建失败")
            return nil
        }
        player.numberOfLoops = -1   // 无限循环
        player.volume = 1.0         // 输出拉到满；实际响度取决于「媒体音量」
        player.prepareToPlay()
        LogCollector.shared.append("alert: 报警音已合成（\(Self.beepFrequency)Hz 三连音）")
        return player
    }

    // MARK: - 音频合成

    /// 合成整段报警音，并封装为内存中的 WAV 数据。
    private static func makeWavData() -> Data {
        let beepSamples = Int(beepDuration * sampleRate)
        let gapSamples = Int(beepGap * sampleRate)
        let silenceSamples = Int(tailSilence * sampleRate)

        var samples: [Int16] = []
        samples.reserveCapacity((beepSamples + gapSamples) * beepCount + silenceSamples)

        for _ in 0..<beepCount {
            appendBeep(into: &samples, sampleCount: beepSamples)
            samples.append(contentsOf: [Int16](repeating: 0, count: gapSamples))
        }
        samples.append(contentsOf: [Int16](repeating: 0, count: silenceSamples))

        return wavContainer(from: samples)
    }

    /// 单个「嘀」：方波 + 起落包络（包络用于消除开关爆音）
    private static func appendBeep(into samples: inout [Int16], sampleCount: Int) {
        let attack = Int(0.004 * sampleRate)
        let release = Int(0.020 * sampleRate)

        for index in 0..<sampleCount {
            let time = Double(index) / sampleRate
            let square: Double = sin(2 * .pi * beepFrequency * time) >= 0 ? 1 : -1

            var envelope = 1.0
            if index < attack {
                envelope = Double(index) / Double(max(attack, 1))
            } else if index > sampleCount - release {
                envelope = Double(sampleCount - index) / Double(max(release, 1))
            }

            let value = square * envelope * amplitude
            let clamped = max(-1.0, min(1.0, value))
            samples.append(Int16(clamped * 32767))
        }
    }

    /// 手工拼 44 字节 WAV 头 + 16bit 单声道 PCM，得到可直接交给 AVAudioPlayer 的数据。
    private static func wavContainer(from samples: [Int16]) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataBytes = UInt32(samples.count * 2)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.append(le32(16))               // PCM 格式块长度
        data.append(le16(1))                // 1 = PCM
        data.append(le16(channels))
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(byteRate))
        data.append(le16(blockAlign))
        data.append(le16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        data.append(le32(dataBytes))
        for sample in samples {
            data.append(le16(UInt16(bitPattern: sample)))
        }
        return data
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}
