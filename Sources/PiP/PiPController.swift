import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// 画中画控制器（PiP）。
///
/// 职责：把帧泵产出的像素缓冲封装为 CMSampleBuffer，
/// 投喂给 AVSampleBufferDisplayLayer，再由 AVPictureInPictureController
/// 以悬浮窗形式展示。
///
/// 时间基说明（重要，曾导致黑屏）：
/// 图层默认时间基从 0 开始、1 倍速推进。若帧的 PTS 使用主机时钟
/// （开机以来的秒数，数值极大），帧会被判定为「远在未来」而永不显示，
/// 表现为黑屏 + 播放器控件。因此本类使用从 0 开始的相对 PTS，
/// 每帧按帧间隔递增；每次 start() 重建显示层并重置 PTS，避免残留状态。
final class PiPController: NSObject {

    static let shared = PiPController()

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var containerView: UIView?
    private let framePump = FramePump()

    /// 下一帧的演示时间戳（相对时间，从 0 开始）
    private var nextPTS = CMTime.zero
    /// 帧间隔（与帧泵的定时间隔保持一致）
    private let frameInterval = CMTime(seconds: 1.0, preferredTimescale: 600)

    private(set) var isActive = false

    private override init() {
        super.init()
        framePump.onFrame = { [weak self] buffer in
            self?.enqueue(buffer)
        }
    }

    // MARK: - 对外接口

    func start() {
        guard !isActive else { return }

        // 音频会话：PiP 在后台存活并持续刷新的关键前提
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)

        // 显示层必须挂在窗口视图层级中，PiP 才能启动
        attachDisplayLayerIfNeeded()

        // 每次启动都创建新的显示层：避免上次会话残留的时间基导致新帧被丢弃
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(origin: .zero, size: TickerFrameRenderer.frameSize)
        containerView?.layer.addSublayer(layer)
        displayLayer = layer

        nextPTS = .zero

        let controller = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
        )
        controller.delegate = self
        pipController = controller

        framePump.start()
        controller.startPictureInPicture()
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        pipController?.stopPictureInPicture()
        framePump.stop()
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        isActive = false
    }

    // MARK: - 帧投喂

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let layer = displayLayer else { return }

        let pts = nextPTS
        nextPTS = CMTimeAdd(nextPTS, frameInterval)

        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(
            from: pixelBuffer,
            presentationTime: pts
        ) else { return }

        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    // MARK: - 层级挂载

    private func attachDisplayLayerIfNeeded() {
        guard containerView == nil else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        guard let window = window else { return }

        // 1x1 容器视图仅用于让显示层进入可见层级，视觉上不可见
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        window.addSubview(view)
        containerView = view
    }
}

// MARK: - 播放代理（伪装直播流）

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // 无限时长：让系统按「直播流」处理，隐藏进度条与跳转控件
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - 画中画生命周期

extension PiPController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        framePump.stop()
        isActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点击「还原」，回到 App 前台
        completionHandler(true)
    }
}
