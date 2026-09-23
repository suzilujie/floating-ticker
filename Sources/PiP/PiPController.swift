import AVFoundation
import AVKit
import Combine
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
final class PiPController: NSObject, ObservableObject {

    static let shared = PiPController()

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var containerView: UIView?
    private let framePump = FramePump()

    /// 报警期间提高帧率的订阅（见 alertFrameInterval 注释）
    private var alertCancellable: AnyCancellable?

    /// 常态帧间隔：1 fps 心跳保活
    private static let idleFrameInterval: TimeInterval = 1.0
    /// 报警帧间隔：4 fps。闪烁为 2 Hz（每相位 0.25 秒），
    /// 4 fps 恰好每相位 1 帧 —— 既是最省电的干净交替，也够用。
    ///
    /// 之所以在意耗电：报警现在**不会自动停止**，可能持续很久，
    /// 8 fps 长时间跑会让画布（600×400，每帧约 1MB）持续分配与重绘。
    private static let alertFrameInterval: TimeInterval = 0.25

    /// 已投喂的帧数（用于日志节流）
    private var frameCount = 0

    /// 用户是否点了浮窗「还原到 App」（区别于主动关闭浮窗）。
    ///
    /// iOS 只在「用户点浮窗回 App」这条路径上回调
    /// restoreUserInterfaceForPictureInPictureStop；点 × / 滑走关闭则不会。
    /// 据此区分"只是想看看 App"与"真的想关掉浮窗"。
    private var restoreRequested = false

    /// 本次启动是否真的收到了 didStart（用于识别"启动请求被系统静默忽略"）
    private var didStartFired = false

    /// 画中画是否处于活动状态（对外可观察，界面据此显示状态）
    @Published private(set) var isActive = false

    private override init() {
        super.init()
        framePump.onFrame = { [weak self] buffer in
            self?.enqueue(buffer)
        }

        // 报警期间把帧泵从 1 fps 提到 8 fps —— 1 fps 下文字闪烁根本闪不起来
        alertCancellable = AlertEngine.shared.$isAlerting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAlerting in
                self?.framePump.setInterval(
                    isAlerting ? Self.alertFrameInterval : Self.idleFrameInterval
                )
            }
    }

    // MARK: - 对外接口

    func start() {
        guard !isActive else { return }
        LogCollector.shared.append("pip: start begin")

        // 音频会话：PiP 在后台存活并持续刷新的关键前提
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        LogCollector.shared.append("pip: start audio session .playback")

        // 后台保活：循环播放静音轨。
        // 仅靠 PiP 不足以在「锁屏」态维持 App 运行 —— 真机实测：锁屏后行情停更、
        // 解锁后 >30 秒不恢复，说明进程被挂起，自愈定时器根本没机会跑。
        // 详见 KeepAliveAudio 的注释。
        KeepAliveAudio.shared.start()

        // 显示层必须挂在窗口视图层级中，PiP 才能启动
        attachDisplayLayerIfNeeded()

        // 每次启动都创建新的显示层，并显式绑定主机时钟时间基
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(origin: .zero, size: TickerFrameRenderer.frameSize)
        containerView?.layer.addSublayer(layer)
        displayLayer = layer
        LogCollector.shared.append("pip: start layer created")

        // 关键修复：图层没有默认时间基（日志已证实为纯黑画面根因），必须显式创建并设置。
        // 没有时间基准时，图层无法判定任何一帧何时显示，于是永不渲染。
        if let timebase = Self.makeControlTimebase() {
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
            LogCollector.shared.append("pip: start controlTimebase set rate=1.0")
        } else {
            LogCollector.shared.append("pip: start controlTimebase 创建失败")
        }

        frameCount = 0

        let controller = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
        )
        controller.delegate = self
        // 兜底机制：应用退到后台时自动转入画中画。
        // 若启动时的手动触发被系统拒绝，用户按 Home 键即可自动转入浮窗。
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        framePump.start()
        isActive = true
        didStartFired = false
        LogCollector.shared.append("pip: start framePump started, 准备启动 PiP")
        attemptStartPiP(retry: 4)
    }

    /// 尝试启动画中画。
    ///
    /// isPictureInPicturePossible 只有在内容真正就绪后才为 true，
    /// 因此在同一时刻立刻调用可能失败；这里做有限重试。
    private func attemptStartPiP(retry: Int) {
        guard let controller = pipController else { return }
        guard retry > 0 else {
            LogCollector.shared.append("pip: start 重试耗尽，放弃启动 PiP")
            isActive = false   // 状态必须如实反映"没起来"，否则界面会谎报已开启
            return
        }

        if controller.isPictureInPicturePossible {
            LogCollector.shared.append("pip: start pipPossible=true，调用 startPictureInPicture")
            controller.startPictureInPicture()

            // 看门狗：iOS 可能"静默忽略"启动请求（不报错、不回调）。
            // 3 秒内没等到 didStart 就判定为未开启，并把结论写进日志 ——
            // 这是判断"自动重启浮窗"能否在 iOS 26 上成立的唯一依据。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                guard self.isActive, !self.didStartFired else { return }
                self.isActive = false
                LogCollector.shared.append("pip: 启动请求未被系统受理（3 秒内无 didStart）")
            }
        } else {
            LogCollector.shared.append("pip: start pipPossible=false，0.5s 后重试（剩余 \(retry - 1)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attemptStartPiP(retry: retry - 1)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        pipController?.stopPictureInPicture()
        framePump.stop()
        removeDisplayLayer()
        KeepAliveAudio.shared.stop()
        isActive = false
        LogCollector.shared.append("pip: stop done")
    }

    /// 把显示层收回容器并移出视图层级。
    ///
    /// 为什么必须做（真机报障）：图层尺寸是画面尺寸（600×400pt），而宿主容器只有
    /// 1×1 且未裁剪。PiP 活动期间画面由系统浮窗负责，图层不参与渲染；一旦 PiP 结束
    /// （例如用户点浮窗「还原」回 App），图层会重新作为内嵌视图以原始尺寸渲染，
    /// 表现就是**盖住 App 界面上半部分的一大块黑底**，且画面横向溢出屏幕。
    ///
    /// 处理顺序：先把图层收回容器尺寸（让系统的还原动画把画面收进角落），
    /// 再延迟移除；捕获具体图层实例而非读 `displayLayer`，避免这 0.35 秒内
    /// 用户重新开启 PiP 时误删新图层。
    private func removeDisplayLayer() {
        guard let layer = displayLayer else { return }
        displayLayer = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = containerView?.bounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            layer.removeFromSuperlayer()
        }
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
            LogCollector.shared.append("pip: enqueue: layer is nil")
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
                LogCollector.shared.append("pip: enqueue #\(frameCount): makeSampleBuffer FAILED")
            }
            return
        }

        if layer.status == .failed {
            layer.flush()
            LogCollector.shared.append("pip: enqueue #\(frameCount): status failed -> flush")
        }
        layer.enqueue(sampleBuffer)

        if frameCount <= 3 {
            LogCollector.shared.append(
                "pip: enqueue #\(frameCount): ok pts=\(pts.seconds) status=\(layer.status) ready=\(layer.isReadyForMoreMediaData) bounds=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
            )
        } else if frameCount == 10 {
            LogCollector.shared.append("pip: enqueue: 已投喂 10 帧")
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
            LogCollector.shared.append("pip: attach no key window")
            return
        }

        // 结论（经两轮对照验证）：
        // - 可见的大容器会阻止 PiP 启动（系统无任何回调）
        // - 渲染是否正常取决于像素缓冲是否有 IOSurface 支撑，与容器可见性无关
        // 故容器恢复为 1x1，渲染由 IOSurface 保证。
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // 第二道保险：图层尺寸远大于 1×1 容器，必须裁剪，
        // 否则一旦图层被内嵌渲染就会溢出成一大块面包住 App 界面。
        view.clipsToBounds = true
        window.addSubview(view)
        containerView = view
        LogCollector.shared.append("pip: attach container 1x1 added")
    }
}

// MARK: - 播放代理（伪装直播流）

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        LogCollector.shared.append("pip: playback setPlaying \(playing)")

        // 浮窗上的暂停键 = 停止报警。
        // 报警会一直响到用户按停止，而用户在别的 App 里时唯一能碰到的控件就是它，
        // 所以必须把「暂停」当作停止用。
        // 2 秒保护：避免系统在报警刚启动时误调 setPlaying(false) 把报警瞬间掐掉。
        guard !playing,
              let started = AlertEngine.shared.alertStartedAt,
              Date().timeIntervalSince(started) > 2 else { return }

        LogCollector.shared.append("alert: 用户按了浮窗暂停键 → 停止报警")
        AlertEngine.shared.stopAlert()
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
        didStartFired = true
        LogCollector.shared.append("pip: didStart")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        framePump.stop()
        isActive = false
        didStartFired = false
        // 必须移除：否则图层会以原始尺寸贴在窗口左上角，盖住 App 界面（见 removeDisplayLayer）
        removeDisplayLayer()

        // 区分两种结束：
        //   ① 用户点浮窗「还原到 App」→ 只是想看看 App，不是要关浮窗 → 自动重启
        //   ② 用户点 × / 滑走关闭       → 尊重意图，不重启，由界面提示并提供一键重开
        let shouldAutoRestart = restoreRequested
        restoreRequested = false

        guard shouldAutoRestart else {
            // 用户主动关闭浮窗。**只结束浮窗本身**，不再连带拆掉后台链路。
            //
            // 这里原先会 `KeepAliveAudio.stop()` + `LiveActivityController.stop()`，
            // 依据是"浮窗都没了，锁屏继续跑也没意义"。但那个前提已经变了：
            // 灵动岛与价格报警现在跟随 **App** 而非浮窗 —— 关掉浮窗后，用户依然
            // 期望锁屏能看牌、后台报警依然生效。若在这里掐掉保活音频，App 会被
            // 系统挂起，锁屏上的数字随即冻住，正是"关掉浮窗 = 全停摆"的老毛病。
            //
            // 保活音频的生命周期因此改由 App 决定：start() 里启动，只在
            // 显式 stop() 时结束 —— 与浮窗是否在场无关。
            LogCollector.shared.append("pip: didStop（用户主动关闭浮窗，后台监控继续运行）")
            return
        }

        LogCollector.shared.append("pip: didStop（「还原到 App」而非关闭），0.4s 后自动重启浮窗")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            // 这 0.4 秒内用户若已手动重开，就不要重复启动
            guard !self.isActive else { return }
            self.start()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点击浮窗「还原」回 App 前台。
        // 注意：这个回调**只在"还原到 App"时触发**，点 × 关闭不会触发 ——
        // 我们据此判断这次 PiP 结束并非用户想关掉浮窗（见 didStop 中的自动重启）。
        restoreRequested = true
        completionHandler(true)
    }
}
