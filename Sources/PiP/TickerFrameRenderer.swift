import CoreGraphics
import CoreVideo
import UIKit

/// 把行情内容绘制成一帧 BGRA 像素缓冲。
///
/// M1 阶段用「占位价格 + 每秒跳动的时钟」验证帧渲染链路：
/// 时钟每秒跳一下，肉眼即可确认帧在持续流动。
/// 后续 M3 会把占位内容替换为真实行情数据。
enum TickerFrameRenderer {

    /// 悬浮窗画面尺寸（宽扁条，比例 16:5）
    static let frameSize = CGSize(width: 640, height: 200)

    /// 首像素诊断只输出一次
    private static var didLogFirstPixel = false

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

        // 深色背景
        context.setFillColor(UIColor(white: 0.07, alpha: 0.94).cgColor)
        context.fill(CGRect(origin: .zero, size: frameSize))

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // 币对标题
        let title = "BTC / USDT  现货" as NSString
        title.draw(at: CGPoint(x: 28, y: 30), withAttributes: [
            .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor(red: 0.89, green: 0.91, blue: 0.95, alpha: 1)
        ])

        // 占位价格（等宽数字，避免宽度抖动）
        let price = "76,000.0" as NSString
        price.draw(at: CGPoint(x: 28, y: 80), withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold),
            .foregroundColor: UIColor.white
        ])

        // 占位涨跌幅（绿色）
        let change = "+0.71%" as NSString
        change.draw(at: CGPoint(x: 28, y: 158), withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium),
            .foregroundColor: UIColor(red: 0.29, green: 0.85, blue: 0.5, alpha: 1)
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
