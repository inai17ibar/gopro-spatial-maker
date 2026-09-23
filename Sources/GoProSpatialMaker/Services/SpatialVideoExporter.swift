import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

struct SpatialExportJob {
    let left: VideoSource
    let right: VideoSource
    let rightOffsetSeconds: Double
    let alignment: StereoAlignment
    let settings: ExportSettings
    let outputURL: URL
}

/// Writes an MV-HEVC (Apple spatial video) QuickTime file from two synchronised clips.
///
/// Each output frame is a pair of tagged pixel buffers (left / right eye) appended through
/// `AVAssetWriterInputTaggedPixelBufferGroupAdaptor`; VideoToolbox encodes them as two MV-HEVC layers
/// together with the spatial metadata (baseline, FOV, disparity adjustment) that visionOS uses to
/// present the file as spatial video in the Photos app.
enum SpatialVideoExporter {
    typealias ProgressHandler = @Sendable (Double, String) -> Void

    static func run(job: SpatialExportJob, progress: ProgressHandler) async throws {
        let settings = job.settings
        let sourceSize = job.left.naturalSize
        var outputSize = settings.resolution.size(sourceSize: sourceSize)
        outputSize.width = floor(outputSize.width / 2) * 2
        outputSize.height = floor(outputSize.height / 2) * 2
        let fps = settings.frameRate.value(sourceFPS: Double(job.left.nominalFrameRate))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))

        // Overlap of both clips measured on the left timeline.
        let leftDuration = job.left.duration.seconds
        let rightDuration = job.right.duration.seconds
        let start = max(0, -job.rightOffsetSeconds)
        let end = min(leftDuration, rightDuration - job.rightOffsetSeconds)
        guard end > start else { throw SpatialMakerError.unsupported("2つの動画に重なる区間がありません") }
        let duration = end - start
        let totalFrames = Int(duration * fps)

        let leftRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: duration, preferredTimescale: 600))
        let rightRange = CMTimeRange(start: CMTime(seconds: start + job.rightOffsetSeconds, preferredTimescale: 600),
                                     duration: leftRange.duration)

        let (leftSource, rightSource) = settings.swapEyes ? (job.right, job.left) : (job.left, job.right)
        let (leftEyeRange, rightEyeRange) = settings.swapEyes ? (rightRange, leftRange) : (leftRange, rightRange)

        let leftCursor = try await VideoFrameCursor(source: leftSource, timeRange: leftEyeRange)
        let rightCursor = try await VideoFrameCursor(source: rightSource, timeRange: rightEyeRange)

        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            try FileManager.default.removeItem(at: job.outputURL)
        }
        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: .mov)

        // MARK: Video input (MV-HEVC)
        let bitrate = Int(settings.bitrateMbps * 1_000_000) * 2
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String: [0, 1],
            kVTCompressionPropertyKey_MVHEVCViewIDs as String: [0, 1],
            kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String: [0, 1],
            kVTCompressionPropertyKey_HasLeftStereoEyeView as String: true,
            kVTCompressionPropertyKey_HasRightStereoEyeView as String: true,
            kVTCompressionPropertyKey_HeroEye as String: kCMFormatDescriptionHeroEye_Left,
            kVTCompressionPropertyKey_ProjectionKind as String: kCMFormatDescriptionProjectionKind_Rectilinear,
        ]
        // Spatial metadata: baseline in micrometres, FOV in millidegrees, disparity in 1/10000 of width.
        compressionProperties[kVTCompressionPropertyKey_StereoCameraBaseline as String] = UInt32(max(0, settings.baselineMillimeters) * 1000)
        compressionProperties[kVTCompressionPropertyKey_HorizontalFieldOfView as String] = UInt32(max(0, settings.horizontalFOVDegrees) * 1000)
        compressionProperties[kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String] = Int32(clamping: settings.disparityAdjustment)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw SpatialMakerError.writerFailed("この環境ではMV-HEVCの書き出しに対応していません (macOS 14以降 / Apple silicon 推奨)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoInput) else { throw SpatialMakerError.writerFailed("映像入力を追加できません") }
        writer.add(videoInput)

        // MARK: Audio input (from the left-eye clip)
        var audioCursor: AudioSampleCursor?
        var audioInput: AVAssetWriterInput?
        if settings.includeAudio, leftSource.hasAudio {
            let cursor = try await AudioSampleCursor(source: leftSource, timeRange: leftEyeRange)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioCursor = cursor
            }
        }

        guard writer.startWriting() else {
            throw SpatialMakerError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        let sessionStart = leftEyeRange.start
        writer.startSession(atSourceTime: sessionStart)

        let renderer = StereoFrameRenderer()
        let outputRect = CGRect(origin: .zero, size: outputSize)

        // MARK: Frame loop
        var frameIndex = 0
        var lastReport = Date.distantPast
        while frameIndex < totalFrames {
            try Task.checkCancellation()

            let leftTime = CMTimeAdd(leftEyeRange.start, CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex)))
            let rightTime = CMTimeAdd(rightEyeRange.start, CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex)))

            guard let leftFrame = leftCursor.frame(atOrBefore: leftTime),
                  let rightFrame = rightCursor.frame(atOrBefore: rightTime) else {
                break // one of the sources ran out early
            }

            let (leftImage, rightImage) = renderer.correctedPair(
                left: leftFrame, right: rightFrame,
                alignment: job.alignment, swapEyes: false, outputSize: outputSize
            )

            guard let pool = adaptor.pixelBufferPool else {
                throw SpatialMakerError.writerFailed("ピクセルバッファプールを取得できません")
            }
            let leftBuffer = try makePixelBuffer(pool: pool)
            let rightBuffer = try makePixelBuffer(pool: pool)
            renderer.render(leftImage.cropped(to: outputRect), to: leftBuffer)
            renderer.render(rightImage.cropped(to: outputRect), to: rightBuffer)

            let taggedBuffers = [
                CMTaggedBuffer(tags: [.videoLayerID(0), .stereoView(.leftEye)], pixelBuffer: leftBuffer),
                CMTaggedBuffer(tags: [.videoLayerID(1), .stereoView(.rightEye)], pixelBuffer: rightBuffer)
            ]

            while !videoInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let presentationTime = CMTimeAdd(sessionStart, CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex)))
            guard adaptor.appendTaggedBuffers(taggedBuffers, withPresentationTime: presentationTime) else {
                throw SpatialMakerError.writerFailed(writer.error?.localizedDescription ?? "フレームの追加に失敗しました")
            }

            if let audioInput, let audioCursor {
                try await drainAudio(cursor: audioCursor, input: audioInput, upTo: presentationTime)
            }

            frameIndex += 1
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.2 {
                lastReport = now
                let fraction = Double(frameIndex) / Double(max(totalFrames, 1))
                progress(fraction, "エンコード中 \(frameIndex)/\(totalFrames) フレーム")
            }
        }

        videoInput.markAsFinished()
        if let audioInput, let audioCursor {
            try await drainAudio(cursor: audioCursor, input: audioInput, upTo: nil)
            audioInput.markAsFinished()
        }

        progress(1, "ファイルを確定中…")
        await writer.finishWriting()
        if writer.status == .failed {
            throw SpatialMakerError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
    }

    // MARK: Helpers

    private static func makePixelBuffer(pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw SpatialMakerError.writerFailed("ピクセルバッファの作成に失敗しました (\(status))")
        }
        return buffer
    }

    /// Appends audio samples whose timestamp is at or before `time` (all remaining samples when nil).
    private static func drainAudio(cursor: AudioSampleCursor, input: AVAssetWriterInput, upTo time: CMTime?) async throws {
        while let next = cursor.peek() {
            if let time, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(next), time) > 0 { return }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            _ = cursor.pop()
            if !input.append(next) { return }
        }
    }
}

// MARK: - Readers

/// Sequential reader over one clip's video track yielding oriented `CIImage`s.
final class VideoFrameCursor {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let orientation: CGAffineTransform
    private var current: (time: CMTime, image: CIImage)?
    private var pending: (time: CMTime, image: CIImage)?
    private var finished = false

    init(source: VideoSource, timeRange: CMTimeRange) async throws {
        guard let track = try await source.asset.loadTracks(withMediaType: .video).first else {
            throw SpatialMakerError.noVideoTrack(source.url)
        }
        let transform = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = timeRange
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpatialMakerError.readerFailed(source.fileName) }
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialMakerError.readerFailed(reader.error?.localizedDescription ?? source.fileName)
        }
        // Core Image's origin is bottom-left; flip the QuickTime (top-left) transform accordingly.
        let size = source.naturalSize
        orientation = transform.isIdentity ? .identity :
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                .concatenating(transform)
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
    }

    /// Latest decoded frame with a timestamp ≤ `time` (or the first frame when the clip starts later).
    func frame(atOrBefore time: CMTime) -> CIImage? {
        if pending == nil { pending = readNext() }
        while let next = pending, CMTimeCompare(next.time, time) <= 0 {
            current = next
            pending = readNext()
        }
        if current == nil, let next = pending {
            current = next
            pending = readNext()
        }
        return current?.image
    }

    private func readNext() -> (time: CMTime, image: CIImage)? {
        guard !finished, let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            finished = true
            return nil
        }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !orientation.isIdentity {
            image = image.transformed(by: orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }
        return (CMSampleBufferGetPresentationTimeStamp(sample), image)
    }
}

/// Sequential reader over one clip's audio track decoded to LPCM.
final class AudioSampleCursor {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var finished = false

    init(source: VideoSource, timeRange: CMTimeRange) async throws {
        guard let track = try await source.asset.loadTracks(withMediaType: .audio).first else {
            throw SpatialMakerError.noAudioTrack(source.url)
        }
        reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = timeRange
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpatialMakerError.readerFailed(source.fileName) }
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialMakerError.readerFailed(reader.error?.localizedDescription ?? source.fileName)
        }
    }

    func peek() -> CMSampleBuffer? {
        if pending == nil, !finished {
            pending = output.copyNextSampleBuffer()
            if pending == nil { finished = true }
        }
        return pending
    }

    func pop() -> CMSampleBuffer? {
        let sample = peek()
        pending = nil
        return sample
    }
}
