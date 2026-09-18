import CoreGraphics
import CoreVideo
import UIKit

/// 把行情内容绘制成一帧 BGRA 像素缓冲。
///
/// 版式：巨号价格（第一行）+ 币对名与涨跌幅（第二行），对齐参考 App 的观感。
/// 无行情时价格显示 `--`，并以「等待行情」占位。
enum TickerFrameRenderer {

    /// 画面画布尺寸（1.5:1，对齐参考 App 的窗口形状）。
    ///
    /// 关键平台约束（真机实测确认）：PiP 窗口的**高度由系统定死**（小档约 96pt），
    /// **宽度 = 窗口高度 × 画面宽高比**。没有任何公开 API 能设定窗口尺寸，
    /// 用户侧的双指捏合缩放也不生效。故调整窗口形状的唯一杠杆是**宽高比**：
    ///
    ///   640×200（3.2:1）→ 窗口约 307×96（细长条）
    ///   640×400（1.6:1）→ 窗口约 154×96（加留白缩小，内容被挤小）
    ///   600×400（1.5:1）→ 窗口约 144×96（本轮：对齐参考 App 的方形观感）
    ///
    /// 字号的设计基准：画布 600 宽映射到窗口约 144pt，缩放比约 0.24。
    /// 价格以 120pt 绘制 → 屏幕上约 29pt，与参考 App 的"巨号价格"观感一致；
    /// 币对名 40pt → 约 9.6pt。**内容铺满整张画布，不再留边**。
    static let frameSize = CGSize(width: 600, height: 400)

    /// 首像素诊断只输出一次
    private static var didLogFirstPixel = false

    /// 价格格式化：1 位小数，**不带千分位**（静态缓存，避免每帧创建）。
    ///
    /// 去掉千分位是刻意的取舍：`78005.1` 是 7 个字符，`78,005.1` 是 8 个，
    /// 在 600 宽的画布里放到同样字号会宽出约 10%。参考 App 也是 7 字符的写法，
    /// 这正是它能把价格做得那么大、而窗口不显得挤的原因。
    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
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

        // 深色背景（铺满整张画布）
        context.setFillColor(UIColor(white: 0.07, alpha: 0.94).cgColor)
        context.fill(CGRect(origin: .zero, size: frameSize))

        // 报警视觉叠在底色之上、内容之下，使用整张画布的坐标
        let alert = AlertEngine.shared
        if alert.isAlerting {
            drawAlertOverlay(context: context, now: now)
        }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // 取当前行情快照：M2 起使用真实数据，无数据时退回占位显示
        let snapshot = TickerStore.shared.snapshot

        // 闪烁相位：报警时以 2 Hz 在两种颜色间交替（频率取值的理由见 blinkHalfPeriod）
        let blinkOn = Int(now.timeIntervalSince1970 / blinkHalfPeriod) % 2 == 0

        // 版式（画布 600×400，映射到窗口约 144×96pt）：
        //   第一行：巨号价格，占满宽度，整窗的视觉主体
        //   第二行：左侧币对名 + 涨跌幅；数据滞后时右侧改为橙色提示
        let margin: CGFloat = 40
        let lineY: CGFloat = 251

        // 最新价（等宽数字，避免跳动时宽度抖动）
        let priceText: String
        if let last = snapshot?.last,
           let formatted = priceFormatter.string(from: NSNumber(value: last)) {
            priceText = formatted
        } else {
            priceText = "--"
        }
        let price = priceText as NSString
        price.draw(at: CGPoint(x: margin, y: 81), withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 120, weight: .bold),
            // 报警时在「报警红 ↔ 纯白」之间闪烁 —— 这是整窗里最抓眼的一处
            .foregroundColor: alert.isAlerting
                ? (blinkOn ? Self.alertRed : UIColor.white)
                : UIColor.white
        ])

        // 第二行左侧：报警时整行替换为报警文案，一行说清发生了什么
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: alert.isAlerting
                ? Self.alertRed
                : UIColor(red: 0.89, green: 0.91, blue: 0.95, alpha: 1)
        ]
        let labelText = alert.isAlerting
            ? alert.alertTitle
            : (snapshot?.displayName ?? "BTC / USDT  永续")
        let label = labelText as NSString
        label.draw(at: CGPoint(x: margin, y: lineY), withAttributes: labelAttrs)

        // 第二行右侧：正常显示 24h 涨跌幅（绿涨红跌）；数据滞后时改为橙色提示。
        // 这取代了原先常驻的时钟：既对齐参考 App 的干净观感，
        // 又保留了"喂价是否还活着"这一判断依据（滞后才提示，正常时不占位）。
        if !alert.isAlerting {
            let staleSeconds = snapshot.map { now.timeIntervalSince($0.updatedAt) } ?? 0
            let trailingText: String
            let trailingColor: UIColor
            let trailingFont: UIFont

            if staleSeconds > 5 {
                trailingText = "⚠ 滞后 \(Int(staleSeconds))s"
                trailingColor = UIColor(red: 0.98, green: 0.72, blue: 0.28, alpha: 1)
                trailingFont = UIFont.monospacedDigitSystemFont(ofSize: 32, weight: .medium)
            } else if let change = snapshot?.changePercent {
                trailingText = String(format: "%+.2f%%", change)
                trailingColor = change >= 0
                    ? UIColor(red: 0.29, green: 0.85, blue: 0.5, alpha: 1)
                    : UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
                trailingFont = UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .medium)
            } else {
                trailingText = "等待行情"
                trailingColor = UIColor(white: 0.55, alpha: 1)
                trailingFont = UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .medium)
            }

            let trailing = trailingText as NSString
            let trailingAttrs: [NSAttributedString.Key: Any] = [
                .font: trailingFont,
                .foregroundColor: trailingColor
            ]
            let labelWidth = label.size(withAttributes: labelAttrs).width
            let trailingWidth = trailing.size(withAttributes: trailingAttrs).width
            // 右对齐，但绝不与左侧文字重叠
            let x = max(margin + labelWidth + 16, frameSize.width - margin - trailingWidth)
            trailing.draw(at: CGPoint(x: x, y: lineY + 4), withAttributes: trailingAttrs)
        }
    }

    // MARK: - 报警视觉

    /// 报警红：比涨跌红更亮更饱和，专门用于「报警」语义，避免与"跌了"混淆
    private static let alertRed = UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1)

    /// 闪烁半周期：0.25 秒 ⇒ 2 Hz。
    ///
    /// 刻意压在 3 Hz 以下：3~30 Hz 的闪烁对光敏性癫痫人群有风险，
    /// 2 Hz 同样醒目但更安全。报警期间帧泵为 8 fps，恰好每相位 2 帧，交替干净。
    private static let blinkHalfPeriod: TimeInterval = 0.25

    /// 整窗红光脉冲 + 四边红框。
    ///
    /// 绘制点在「底色之后、内容之前」，使用整张画布的坐标。
    private static func drawAlertOverlay(context: CGContext, now: Date) {
        let phase = Int(now.timeIntervalSince1970 / blinkHalfPeriod) % 2

        // 红光脉冲：两级透明度交替，形成呼吸感而非硬闪
        context.setFillColor(
            UIColor(red: 0.98, green: 0.30, blue: 0.30, alpha: phase == 0 ? 0.34 : 0.12).cgColor
        )
        context.fill(CGRect(origin: .zero, size: frameSize))

        // 四边红框：画布 600 宽映射到窗口约 144pt，14 单位 ≈ 3.4pt，足够醒目
        context.setStrokeColor(UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 0.95).cgColor)
        context.setLineWidth(14)
        context.stroke(CGRect(origin: .zero, size: frameSize).insetBy(dx: 7, dy: 7))
    }
}
