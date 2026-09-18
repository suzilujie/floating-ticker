import CoreGraphics
import CoreVideo
import UIKit

/// 把行情内容绘制成一帧 BGRA 像素缓冲。
///
/// M1 阶段用「占位价格 + 每秒跳动的时钟」验证帧渲染链路：
/// 时钟每秒跳一下，肉眼即可确认帧在持续流动。
/// 后续 M3 会把占位内容替换为真实行情数据。
enum TickerFrameRenderer {

    /// 画面画布尺寸。
    ///
    /// 关键平台约束（真机实测确认）：PiP 窗口的**高度由系统定死**（小档约 96pt），
    /// **宽度 = 窗口高度 × 画面宽高比**。没有任何公开 API 能设定窗口尺寸，
    /// 用户侧的双指捏合缩放也不生效。因此「把浮窗改小」的唯一杠杆是**调小宽高比**：
    ///
    ///   640×200（3.2:1）→ 窗口约 307×96
    ///   640×400（1.6:1）→ 窗口约 154×96（面积正好减半）
    ///
    /// 画布加高后，行情条仍按原设计绘制在 200 高的内容带内并垂直居中，
    /// 上下多出的部分为底色留白。附带收益：系统的关闭按钮与画中画图标压在窗口
    /// 四角，原先会盖住左上角的币对名，加留白后控件落进留白区，不再遮挡文字。
    static let frameSize = CGSize(width: 640, height: 400)

    /// 内容区高度（行情条本身的设计高度，不随画布高度变化）
    private static let contentHeight: CGFloat = 200

    /// 内容区在画布中的垂直偏移（使行情条在加高后的画布中居中）
    private static var contentOffsetY: CGFloat {
        (frameSize.height - contentHeight) / 2
    }

    /// 首像素诊断只输出一次
    private static var didLogFirstPixel = false

    /// 价格格式化：千分位 + 1 位小数（静态缓存，避免每帧创建）
    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.groupingSeparator = ","
        return formatter
    }()

    /// 渲染一帧。
    static func render(now: Date) -> CVPixelBuffer? {
        guard let pixelBuffer = makePixelBuffer(size: frameSize) else {
            LogCollector.shared.append("render: pixelBuffer 创建失败")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(frameSize.width),
            height: Int(frameSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            LogCollector.shared.append("render: CGContext 创建失败")
            return nil
        }

        draw(context: context, now: now)

        // 诊断：读取首像素的 BGRA，确认内容确实写入了缓冲
        // （若为 0,0,0,0 则说明绘制没生效；若为深灰则说明内容正常，问题在显示端）
        if !Self.didLogFirstPixel, let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            LogCollector.shared.append(
                "render: first pixel BGRA=(\(bytes[0]),\(bytes[1]),\(bytes[2]),\(bytes[3]))"
            )
            Self.didLogFirstPixel = true
        }

        return pixelBuffer
    }

    // MARK: - 私有

    private static func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        // IOSurface 支撑是 AVSampleBufferDisplayLayer 硬件合成管线的前提：
        // 缺少该键时，帧能成功入队、图层状态正常，但画面始终不显示（纯黑）。
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func draw(context: CGContext, now: Date) {
        // 翻转到 UIKit 坐标系（原点左上角），否则文字会上下颠倒
        context.translateBy(x: 0, y: frameSize.height)
        context.scaleBy(x: 1, y: -1)

        // 深色背景（铺满整个画布，含上下留白）
        context.setFillColor(UIColor(white: 0.07, alpha: 0.94).cgColor)
        context.fill(CGRect(origin: .zero, size: frameSize))

        // 内容区下移「留白的一半」，使其在加高后的画布中垂直居中。
        // 注：上一行已把坐标系翻转为 UIKit 式（原点左上、+y 向下），故此处为下移。
        context.translateBy(x: 0, y: contentOffsetY)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // 取当前行情快照：M2 起使用真实数据，无数据时退回占位显示
        let snapshot = TickerStore.shared.snapshot

        // 币对标题
        let title = (snapshot?.displayName ?? "BTC / USDT  永续") as NSString
        title.draw(at: CGPoint(x: 28, y: 30), withAttributes: [
            .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor(red: 0.89, green: 0.91, blue: 0.95, alpha: 1)
        ])

        // 最新价（等宽数字，避免宽度抖动）
        let priceText: String
        if let last = snapshot?.last,
           let formatted = priceFormatter.string(from: NSNumber(value: last)) {
            priceText = formatted
        } else {
            priceText = "--"
        }
        let price = priceText as NSString
        price.draw(at: CGPoint(x: 28, y: 80), withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold),
            .foregroundColor: UIColor.white
        ])

        // 24h 涨跌幅（绿涨红跌）
        let changeText: String
        let changeColor: UIColor
        if let change = snapshot?.changePercent {
            changeText = String(format: "%+.2f%%", change)
            changeColor = change >= 0
                ? UIColor(red: 0.29, green: 0.85, blue: 0.5, alpha: 1)
                : UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
        } else {
            changeText = "等待行情"
            changeColor = UIColor(white: 0.55, alpha: 1)
        }
        let change = changeText as NSString
        change.draw(at: CGPoint(x: 28, y: 158), withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium),
            .foregroundColor: changeColor
        ])

        // 右上角实时时钟：每秒跳动，证明帧泵在持续出帧
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let clock = formatter.string(from: now) as NSString
        let clockAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular),
            .foregroundColor: UIColor(white: 0.6, alpha: 1)
        ]
        let clockSize = clock.size(withAttributes: clockAttrs)
        clock.draw(at: CGPoint(x: frameSize.width - clockSize.width - 28, y: 158), withAttributes: clockAttrs)
    }
}
