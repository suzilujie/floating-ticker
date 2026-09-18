import CoreVideo
import Foundation

/// 帧泵（Frame Pump）：按当前间隔生成帧并派发。
///
/// 间隔可变：
/// - 常态 1 fps —— 心跳保活，价格变化另有事件驱动的即时出帧，够用且省电；
/// - 报警期间提高到 8 fps —— 文字颜色闪烁需要足够的出帧密度，
///   否则 1 fps 下根本闪不起来。
final class FramePump {

    /// 每出一帧的回调
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var timer: Timer?
    private(set) var interval: TimeInterval

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

    /// 运行中调整出帧间隔（报警时提高帧率以实现闪烁）
    func setInterval(_ newInterval: TimeInterval) {
        guard newInterval != interval else { return }
        interval = newInterval
        guard timer != nil else { return }   // 未运行则只记下新间隔，start() 时生效
        start()
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
