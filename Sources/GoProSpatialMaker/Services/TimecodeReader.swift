import Foundation
import AVFoundation
import CoreMedia

struct StartTimecode {
    /// Real elapsed time since 00:00:00:00 represented by the timecode (frame count × frame duration).
    let seconds: Double
    let display: String
    let frameQuanta: UInt32
    let isDropFrame: Bool
}

/// Reads the first sample of a QuickTime timecode ('tmcd' / 'tc64') track.
/// GoPro cameras write one when timecode sync has been enabled through the Quik app.
enum TimecodeReader {
    static func readStartTimecode(asset: AVAsset) async throws -> StartTimecode? {
        let tracks = try await asset.loadTracks(withMediaType: .timecode)
        guard let track = tracks.first else { return nil }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialMakerError.readerFailed(reader.error?.localizedDescription ?? "timecode track")
        }
        defer { reader.cancelReading() }

        // The reader may emit data-less marker buffers (e.g. edit boundaries) before the first real sample.
        var firstSample: CMSampleBuffer?
        while let candidate = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(candidate) > 0, CMSampleBufferGetDataBuffer(candidate) != nil {
                firstSample = candidate
                break
            }
        }
        guard let sample = firstSample,
              let formatDescription = CMSampleBufferGetFormatDescription(sample),
              let blockBuffer = CMSampleBufferGetDataBuffer(sample) else {
            return nil
        }

        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(formatDescription)
        let frameQuanta = CMTimeCodeFormatDescriptionGetFrameQuanta(formatDescription)
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(formatDescription)
        let isDropFrame = (flags & kCMTimeCodeFlag_DropFrame) != 0
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes)
        guard status == kCMBlockBufferNoErr else { return nil }

        let frameNumber: Int64
        switch mediaSubType {
        case kCMTimeCodeFormatType_TimeCode32:
            guard length >= 4 else { return nil }
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            frameNumber = Int64(Int32(bitPattern: raw))
        case kCMTimeCodeFormatType_TimeCode64:
            guard length >= 8 else { return nil }
            var raw: UInt64 = 0
            for b in bytes[0..<8] { raw = raw << 8 | UInt64(b) }
            frameNumber = Int64(bitPattern: raw)
        default:
            return nil
        }
        guard frameNumber >= 0, frameDuration.isNumeric, frameDuration.seconds > 0 else { return nil }

        let seconds = Double(frameNumber) * frameDuration.seconds
        return StartTimecode(
            seconds: seconds,
            display: format(frameNumber: frameNumber, frameQuanta: frameQuanta, isDropFrame: isDropFrame),
            frameQuanta: frameQuanta,
            isDropFrame: isDropFrame
        )
    }

    /// Formats a frame count as HH:MM:SS:FF (or HH:MM:SS;FF for drop-frame) using SMPTE rules.
    static func format(frameNumber: Int64, frameQuanta: UInt32, isDropFrame: Bool) -> String {
        let fps = Int64(frameQuanta)
        guard fps > 0 else { return "--:--:--:--" }
        var frames = frameNumber
        if isDropFrame {
            // Reinsert the dropped frame numbers (2 per minute except every 10th minute, scaled for 60 fps).
            let dropPerMinute = fps / 15 // 2 for 30 fps, 4 for 60 fps
            let framesPer10Minutes = fps * 600 - dropPerMinute * 9
            let framesPerMinute = fps * 60 - dropPerMinute
            let d = frames / framesPer10Minutes
            let m = frames % framesPer10Minutes
            if m > dropPerMinute {
                frames += dropPerMinute * 9 * d + dropPerMinute * ((m - dropPerMinute) / framesPerMinute)
            } else {
                frames += dropPerMinute * 9 * d
            }
        }
        let ff = frames % fps
        let totalSeconds = frames / fps
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = (totalSeconds / 3600) % 24
        let separator = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, separator, ff)
    }
}
