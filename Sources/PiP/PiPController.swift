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
/// 时间基（曾导致黑屏，本轮显式绑定）：
/// 显式创建 controlTimebase 并绑定主机时钟，帧 PTS 同样取主机时钟，
/// 二者严格对齐，确保帧到达即显示。
final class PiPController: NSObject {

    static let shared = PiPController()

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var containerView: UIView?
    private let framePump = FramePump()

    /// 已投喂的帧数（用于日志节流）
    private var frameCount = 0

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
        LogCollector.shared.append("start: begin")

        // 音频会话：PiP 在后台存活并持续刷新的关键前提
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        LogCollector.shared.append("start: audio session .playback")

        // 显示层必须挂在窗口视图层级中，PiP 才能启动
        attachDisplayLayerIfNeeded()

        // 每次启动都创建新的显示层，并显式绑定主机时钟时间基
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = containerView?.bounds ?? CGRect(origin: .zero, size: TickerFrameRenderer.frameSize)
        containerView?.layer.addSublayer(layer)
        displayLayer = layer
        LogCollector.shared.append("start: layer created")

        // 关键修复：图层没有默认时间基（日志已证实为纯黑画面根因），必须显式创建并设置。
        // 没有时间基准时，图层无法判定任何一帧何时显示，于是永不渲染。
        if let timebase = Self.makeControlTimebase() {
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
            LogCollector.shared.append("start: controlTimebase set rate=1.0")
        } else {
            LogCollector.shared.append("start: controlTimebase 创建失败")
        }

        frameCount = 0

        let controller = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
        )
        controller.delegate = self
        pipController = controller

        framePump.start()
        isActive = true
        LogCollector.shared.append("start: framePump started, 准备启动 PiP")
        attemptStartPiP(retry: 4)
    }

    /// 尝试启动画中画。
    ///
    /// isPictureInPicturePossible 只有在内容真正就绪后才为 true，
    /// 因此在同一时刻立刻调用可能失败；这里做有限重试。
    private func attemptStartPiP(retry: Int) {
        guard let controller = pipController else { return }
        guard retry > 0 else {
            LogCollector.shared.append("start: 重试耗尽，放弃启动 PiP")
            return
        }

        if controller.isPictureInPicturePossible {
            LogCollector.shared.append("start: pipPossible=true，调用 startPictureInPicture")
            controller.startPictureInPicture()
        } else {
            LogCollector.shared.append("start: pipPossible=false，0.5s 后重试（剩余 \(retry - 1)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attemptStartPiP(retry: retry - 1)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        pipController?.stopPictureInPicture()
        framePump.stop()
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        isActive = false
        LogCollector.shared.append("stop: done")
    }

    // MARK: - 时间基

    /// 创建以主机时钟为源的时间基。
    ///
    /// 注意：CMTimebaseCreateWithSourceClock 在 Swift 中的签名为
    /// (allocator:sourceClock:timebaseOut:)，即通过输出参数返回时间基，
    /// 函数本身返回 OSStatus 状态码 —— 早期尝试漏传 timebaseOut 导致编译失败。
    private static func makeControlTimebase() -> CMTimebase? {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard status == noErr else { return nil }
        return timebase
    }

    // MARK: - 帧投喂

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let layer = displayLayer else {
            LogCollector.shared.append("enqueue: layer is nil")
            return
        }
        frameCount += 1

        // PTS 取图层自身时间基的当前时间：保证帧「立即到期」，而非落在图层时钟的未来
        let pts: CMTime
        if let timebase = layer.controlTimebase {
            pts = CMTimebaseGetTime(timebase)
        } else {
            pts = CMClockGetTime(CMClockGetHostTimeClock())
        }
        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(
            from: pixelBuffer,
            presentationTime: pts
        ) else {
            if frameCount <= 3 {
                LogCollector.shared.append("enqueue #\(frameCount): makeSampleBuffer FAILED")
            }
            return
        }

        if layer.status == .failed {
            layer.flush()
            LogCollector.shared.append("enqueue #\(frameCount): status failed -> flush")
        }
        layer.enqueue(sampleBuffer)

        if frameCount <= 3 {
            LogCollector.shared.append(
                "enqueue #\(frameCount): ok pts=\(pts.seconds) status=\(layer.status) ready=\(layer.isReadyForMoreMediaData) bounds=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
            )
        } else if frameCount == 10 {
            LogCollector.shared.append("enqueue: 已投喂 10 帧")
        }
    }

    // MARK: - 层级挂载

    private func attachDisplayLayerIfNeeded() {
        guard containerView == nil else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        guard let window = window else {
            LogCollector.shared.append("attach: no key window")
            return
        }

        // 容器视图必须有真实尺寸且处于可见状态：
        // 早期使用 1x1 视图导致显示层可能被判为无可渲染区域（画面纯黑）。
        // 这里用与画面同比例的 320x100，放在窗口底部作为可见预览。
        let previewSize = CGSize(
            width: 320,
            height: 320 * TickerFrameRenderer.frameSize.height / TickerFrameRenderer.frameSize.width
        )
        let view = UIView(frame: CGRect(
            x: 8,
            y: window.bounds.height - previewSize.height - 40,
            width: previewSize.width,
            height: previewSize.height
        ))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        containerView = view
        LogCollector.shared.append(
            "attach: container \(Int(previewSize.width))x\(Int(previewSize.height)) visible=\(!view.isHidden) alpha=\(view.alpha)"
        )
    }
}

// MARK: - 播放代理（伪装直播流）

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        LogCollector.shared.append("playback: setPlaying \(playing)")
    }

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
    ) {
        LogCollector.shared.append("pip: renderSize \(newRenderSize.width)x\(newRenderSize.height)")
    }

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

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        LogCollector.shared.append("pip: willStart")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        LogCollector.shared.append("pip: 启动失败 error=\(error.localizedDescription)")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
        LogCollector.shared.append("pip: didStart")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        framePump.stop()
        isActive = false
        LogCollector.shared.append("pip: didStop")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点击「还原」，回到 App 前台
        completionHandler(true)
    }
}
