import Foundation
import AVFoundation
import CoreMedia

/// A loaded input clip together with the metadata needed for sync and export.
struct VideoSource: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let asset: AVURLAsset
    let duration: CMTime
    let naturalSize: CGSize
    let nominalFrameRate: Float
    let hasAudio: Bool
    /// Start timecode (in seconds since 00:00:00:00) if the clip has a timecode track.
    let startTimecodeSeconds: Double?
    let startTimecodeString: String?

    static func == (lhs: VideoSource, rhs: VideoSource) -> Bool { lhs.id == rhs.id }

    var fileName: String { url.lastPathComponent }

    static func load(url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SpatialMakerError.noVideoTrack(url)
        }
        let (naturalSize, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let orientedSize = naturalSize.applying(transform)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let timecode = try? await TimecodeReader.readStartTimecode(asset: asset)

        return VideoSource(
            url: url,
            asset: asset,
            duration: duration,
            naturalSize: CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height)),
            nominalFrameRate: fps,
            hasAudio: !audioTracks.isEmpty,
            startTimecodeSeconds: timecode?.seconds,
            startTimecodeString: timecode?.display
        )
    }
}

enum SpatialMakerError: LocalizedError {
    case noVideoTrack(URL)
    case noAudioTrack(URL)
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url): return "\(url.lastPathComponent) に映像トラックがありません"
        case .noAudioTrack(let url): return "\(url.lastPathComponent) に音声トラックがありません"
        case .readerFailed(let msg): return "読み込みエラー: \(msg)"
        case .writerFailed(let msg): return "書き出しエラー: \(msg)"
        case .cancelled: return "キャンセルされました"
        case .unsupported(let msg): return msg
        }
    }
}
