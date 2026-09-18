import CoreVideo
import Foundation

/// 帧泵（Frame Pump）：按固定间隔生成帧并派发。
///
/// M1 用 1 秒间隔——时钟每秒跳动，用最小成本证明「帧在持续流动」。
/// 后续 M3 会改为「事件驱动 + 自适应帧率」：
/// 价格变化时立即出帧，静止时降到 1 fps 心跳保活。
final class FramePump {

    /// 每出一帧的回调
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 加入 .common 模式，保证界面滚动时定时器仍触发
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick() // 立即出第一帧，不等第一个间隔
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let pixelBuffer = TickerFrameRenderer.render(now: Date()) else { return }
        onFrame?(pixelBuffer)
    }
}
