import Foundation

enum OutputResolution: String, CaseIterable, Identifiable, Codable {
    case source = "Source"
    case uhd4k = "3840×2160"
    case fhd = "1920×1080"

    var id: String { rawValue }

    func size(sourceSize: CGSize) -> CGSize {
        switch self {
        case .source: return sourceSize
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .fhd: return CGSize(width: 1920, height: 1080)
        }
    }
}

enum OutputFrameRate: String, CaseIterable, Identifiable, Codable {
    case source = "Source"
    case fps30 = "30 fps"
    case fps60 = "60 fps"

    var id: String { rawValue }

    func value(sourceFPS: Double) -> Double {
        switch self {
        case .source: return sourceFPS
        case .fps30: return 30
        case .fps60: return 60
        }
    }
}

/// Settings that control the MV-HEVC output and its spatial metadata.
struct ExportSettings: Equatable, Codable {
    var resolution: OutputResolution = .uhd4k
    var frameRate: OutputFrameRate = .fps30
    /// Average bitrate per eye in megabits per second.
    var bitrateMbps: Double = 40
    /// Distance between the two lens centres in millimetres. Two GoPro 12s side by side ≈ 72 mm.
    var baselineMillimeters: Double = 72
    /// Horizontal field of view of one eye in degrees. GoPro Linear (16:9) ≈ 90°, Wide ≈ 118°.
    var horizontalFOVDegrees: Double = 90
    /// Horizontal disparity adjustment written to the file, in thousandths of the frame width (-10000...10000).
    var disparityAdjustment: Int = 0
    var includeAudio: Bool = true
    var swapEyes: Bool = false
}
