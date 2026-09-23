import XCTest
import AVFoundation
import CoreImage
@testable import GoProSpatialMaker

/// End-to-end smoke test: two synthetic clips (the right one starting 0.2 s later) are exported to an
/// MV-HEVC .mov and the result is inspected with AVFoundation.
final class SpatialVideoExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoProSpatialMakerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExportsMVHEVCWithTwoLayersAndAudio() async throws {
        let leftURL = tempDir.appendingPathComponent("left.mov")
        let rightURL = tempDir.appendingPathComponent("right.mov")
        try await SyntheticClip.write(to: leftURL, seconds: 2, color: CIColor(red: 0.9, green: 0.2, blue: 0.2), toneHz: 440)
        try await SyntheticClip.write(to: rightURL, seconds: 2, color: CIColor(red: 0.2, green: 0.2, blue: 0.9), toneHz: 660)

        let left = try await VideoSource.load(url: leftURL)
        let right = try await VideoSource.load(url: rightURL)
        XCTAssertTrue(left.hasAudio)
        XCTAssertEqual(left.naturalSize, CGSize(width: 640, height: 360))

        var settings = ExportSettings()
        settings.resolution = .source
        settings.frameRate = .fps30
        settings.bitrateMbps = 4
        let outputURL = tempDir.appendingPathComponent("spatial.mov")
        let job = SpatialExportJob(
            left: left, right: right,
            rightOffsetSeconds: -0.2, // right camera started 0.2 s later
            alignment: .identity,
            settings: settings,
            outputURL: outputURL
        )
        try await SpatialVideoExporter.run(job: job) { _, _ in }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.8, accuracy: 0.1)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let descriptions = try await videoTracks[0].load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)

        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let keys = extensions.keys.sorted()
        XCTAssertEqual(extensions[kCMFormatDescriptionExtension_HasLeftStereoEyeView as String] as? Bool, true, "\(keys)")
        XCTAssertEqual(extensions[kCMFormatDescriptionExtension_HasRightStereoEyeView as String] as? Bool, true, "\(keys)")
        XCTAssertNotNil(extensions[kCMFormatDescriptionExtension_StereoCameraBaseline as String], "\(keys)")
        XCTAssertNotNil(extensions[kCMFormatDescriptionExtension_HorizontalFieldOfView as String], "\(keys)")

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testAudioSyncOnRealClips() async throws {
        let leftURL = tempDir.appendingPathComponent("left.mov")
        let rightURL = tempDir.appendingPathComponent("right.mov")
        // Same noise burst (no tone, which would dominate the correlation), right clip started 0.25 s later.
        try await SyntheticClip.write(to: leftURL, seconds: 4, color: .red, toneHz: 0, noiseStart: 1.0)
        try await SyntheticClip.write(to: rightURL, seconds: 4, color: .blue, toneHz: 0, noiseStart: 0.75)

        let result = try await AudioSyncEstimator.estimateOffset(
            reference: AVURLAsset(url: leftURL), target: AVURLAsset(url: rightURL), analysisDuration: 10
        )
        XCTAssertEqual(result.offsetSeconds, -0.25, accuracy: 0.01)
    }
}

/// Writes a small H.264 + AAC test clip with a solid colour and a tone plus an optional noise burst.
enum SyntheticClip {
    static func write(to url: URL, seconds: Double, color: CIColor, toneHz: Double, noiseStart: Double? = nil) async throws {
        let fps = 30
        let size = CGSize(width: 640, height: 360)
        let sampleRate = 48_000
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(videoInput)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var audioFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
        ], sourceFormatHint: audioFormat)
        writer.add(audioInput)

        guard writer.startWriting() else { throw writer.error ?? SpatialMakerError.writerFailed("startWriting") }
        writer.startSession(atSourceTime: .zero)

        let totalSamples = Int(seconds * Double(sampleRate))
        var rng: UInt64 = 12345
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            var v = 0.2 * sin(2 * .pi * toneHz * t)
            if let noiseStart, t >= noiseStart, t < noiseStart + 0.5 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                v += Double(Int64(bitPattern: rng >> 11) % 20000) / 20000 * 0.8
            }
            samples[i] = Float(v)
        }

        // AVAssetWriter interleaves tracks and stops accepting video while audio lags, so audio is fed
        // whenever the video input is not ready.
        let context = CIContext()
        let frameCount = Int(seconds * Double(fps))
        let samplesPerFrame = sampleRate / fps
        var audioOffset = 0
        func appendAudioChunk() throws {
            let end = min(totalSamples, audioOffset + samplesPerFrame)
            let sampleBuffer = try makeAudioSampleBuffer(samples: Array(samples[audioOffset..<end]),
                                                         startSample: audioOffset, format: audioFormat!, sampleRate: sampleRate)
            guard audioInput.append(sampleBuffer) else { throw writer.error ?? SpatialMakerError.writerFailed("append audio") }
            audioOffset = end
            if audioOffset == totalSamples { audioInput.markAsFinished() }
        }
        for i in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? SpatialMakerError.writerFailed("writer failed") }
                if audioOffset < totalSamples, audioInput.isReadyForMoreMediaData {
                    try appendAudioChunk()
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            guard let pool = adaptor.pixelBufferPool else { throw SpatialMakerError.writerFailed("pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw SpatialMakerError.writerFailed("buffer") }
            // Moving bar so the encoder has something to do and frames are distinguishable.
            let bar = CIImage(color: .white).cropped(to: CGRect(x: CGFloat(i * 8 % Int(size.width)), y: 0, width: 16, height: size.height))
            let image = bar.composited(over: CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)))
            context.render(image, to: buffer)
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? SpatialMakerError.writerFailed("append video")
            }
            if audioOffset < totalSamples, audioInput.isReadyForMoreMediaData { try appendAudioChunk() }
        }
        videoInput.markAsFinished()
        while audioOffset < totalSamples {
            if writer.status == .failed { throw writer.error ?? SpatialMakerError.writerFailed("writer failed") }
            if audioInput.isReadyForMoreMediaData { try appendAudioChunk() } else { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? SpatialMakerError.writerFailed("finishWriting") }
    }

    private static func makeAudioSampleBuffer(samples: [Float], startSample: Int, format: CMAudioFormatDescription,
                                              sampleRate: Int) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                        flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw SpatialMakerError.writerFailed("block buffer \(status)") }
        status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) }
        guard status == kCMBlockBufferNoErr else { throw SpatialMakerError.writerFailed("replace bytes \(status)") }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil,
                                      refcon: nil, formatDescription: format, sampleCount: samples.count,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw SpatialMakerError.writerFailed("sample buffer \(status)") }
        return sampleBuffer
    }
}
