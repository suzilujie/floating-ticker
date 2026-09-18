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
        return sampleBuffer
    }
}
