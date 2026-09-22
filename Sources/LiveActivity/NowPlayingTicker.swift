import Combine
import Foundation
import MediaPlayer

/// 把行情写入系统的「正在播放」信息（锁屏媒体卡 / 控制中心 / 灵动岛展开态）。
///
/// **为什么加这条路**：实时活动（Live Activity）在锁屏/后台的**本地**更新是否被系统采用，
/// 我们始终没拿到直接证据 —— 日志只能证明「我们调用了 update」，证明不了「系统用上了」。
/// 而「正在播放」是**音乐类 App 天天在后台更新的通道**，属于官方支持的后台刷新路径：
/// 我们为了锁屏保活本来就在持续播放音频（`KeepAliveAudio`），**已经是系统的「正在播放」App**，
/// 只是媒体卡上的内容是空的。把价格写进去，等于零成本换来一块锁屏大字显示位。
///
/// 说明：会占用系统「正在播放」槽位（与音乐类 App 互斥）—— 但我们的音频保活本就占着它，
/// 所以**不新增冲突**，只是把这块已有的位置用起来。
final class NowPlayingTicker {

    static let shared = NowPlayingTicker()

    private var cancellable: AnyCancellable?
    private var lastUpdateAt: Date?

    /// 写入节流：1 次/秒。媒体信息更新过快会拖慢系统锁屏 UI，与行情节奏对齐即可。
    private static let minUpdateInterval: TimeInterval = 1.0

    private init() {}

    func start() {
        guard cancellable == nil else { return }

        // 我们确实在播放音频（保活音轨），如实声明为「播放中」
        MPNowPlayingInfoCenter.default().playbackState = .playing

        cancellable = TickerStore.shared.tickPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.update(snapshot)
            }

        LogCollector.shared.append("nowplaying: 已接管「正在播放」信息（锁屏媒体卡显示行情）")
    }

    private func update(_ snapshot: TickerSnapshot) {
        if let last = lastUpdateAt, Date().timeIntervalSince(last) < Self.minUpdateInterval {
            return
        }
        lastUpdateAt = Date()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "BTC / USDT  永续"
        info[MPMediaItemPropertyArtist] = String(
            format: "%.1f    %+.2f%%", snapshot.last, snapshot.changePercent
        )
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
