import AVFoundation
import CoreMedia

/// 把像素缓冲（CVPixelBuffer）封装为 CMSampleBuffer，
/// 供 AVSampleBufferDisplayLayer 播放。
enum SampleBufferFactory {

    /// 构造一帧可播放的 sample buffer。
    /// - Parameters:
    ///   - pixelBuffer: 已绘制好内容的 BGRA 像素缓冲
    ///   - presentationTime: 演示时间戳（应单调递增）
    static func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription = formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            return nil
        }

        // 关键：告诉显示层"这一帧立即显示"，不要等待时间基准到点。
        // 直播式内容（PTS 与系统时钟基准不一定严格对齐）常因缺少该附件而
        // 始终不显示，表现为纯黑画面。
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )

        return sampleBuffer
    }
}
