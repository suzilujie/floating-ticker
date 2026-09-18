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
final class PiPController: NSObject {

    static let shared = PiPController()

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let framePump = FramePump()
    private var pipController: AVPictureInPictureController?
    private var containerView: UIView?
    private let clock = CMClockGetHostTimeClock()

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

        let controller = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
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
        isActive = false
    }

    // MARK: - 帧投喂

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        // 用主机时钟做演示时间戳，保证单调递增
        let now = CMClockGetTime(clock)
        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(
            from: pixelBuffer,
            presentationTime: now
        ) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - 层级挂载

    private func attachDisplayLayerIfNeeded() {
        guard containerView == nil else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
            ?? UIApplication.shared.windows.first
        guard let window = window else { return }

        // 1x1 容器视图仅用于让显示层进入可见层级，视觉上不可见
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        displayLayer.frame = CGRect(
            origin: .zero,
            size: TickerFrameRenderer.frameSize
        )
        displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(displayLayer)
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
        completionHandler: @escaping () -> Void
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
