import XCTest
@testable import GoProSpatialMaker

final class AudioSyncEstimatorTests: XCTestCase {
    private func noise(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 20000) / 10000 - 1
        }
    }

    func testDetectsRightClipStartingEarlier() throws {
        // The right camera started 0.5 s before the left one, so the same sound appears 0.5 s later in the right file.
        let fs = 8000.0
        let delaySamples = 4000
        let base = noise(count: 60_000, seed: 42)
        let left = Array(base[0..<48_000])
        let right = Array(repeating: Float(0), count: delaySamples) + Array(base[0..<44_000])

        let result = try AudioSyncEstimator.estimateOffset(reference: left, target: right, sampleRate: fs)
        XCTAssertEqual(result.offsetSeconds, Double(delaySamples) / fs, accuracy: 1 / fs)
        XCTAssertGreaterThan(result.confidence, 0.3)
    }

    func testDetectsRightClipStartingLater() throws {
        let fs = 8000.0
        let delaySamples = 2500
        let base = noise(count: 60_000, seed: 7)
        let left = Array(repeating: Float(0), count: delaySamples) + Array(base[0..<44_000])
        let right = Array(base[0..<48_000])

        let result = try AudioSyncEstimator.estimateOffset(reference: left, target: right, sampleRate: fs)
        XCTAssertEqual(result.offsetSeconds, -Double(delaySamples) / fs, accuracy: 1 / fs)
    }
}

final class TimecodeFormatTests: XCTestCase {
    func testNonDropFrame() {
        XCTAssertEqual(TimecodeReader.format(frameNumber: 0, frameQuanta: 30, isDropFrame: false), "00:00:00:00")
        XCTAssertEqual(TimecodeReader.format(frameNumber: 30 * 3661 + 5, frameQuanta: 30, isDropFrame: false), "01:01:01:05")
    }

    func testDropFrame() {
        // Frame numbers ;00 and ;01 are skipped at every minute except multiples of ten.
        XCTAssertEqual(TimecodeReader.format(frameNumber: 1799, frameQuanta: 30, isDropFrame: true), "00:00:59;29")
        XCTAssertEqual(TimecodeReader.format(frameNumber: 1800, frameQuanta: 30, isDropFrame: true), "00:01:00;02")
        // 10 minutes = 17982 frames, displayed exactly as 00:10:00;00
        XCTAssertEqual(TimecodeReader.format(frameNumber: 17982, frameQuanta: 30, isDropFrame: true), "00:10:00;00")
    }
}

final class StereoAlignmentTests: XCTestCase {
    func testIdentityTransform() {
        let t = StereoAlignment.identity.transform(for: CGSize(width: 100, height: 50))
        XCTAssertTrue(t.isIdentity)
    }

    func testHorizontalShiftMovesByFractionOfWidth() {
        var a = StereoAlignment.identity
        a.horizontalShift = 0.1
        let t = a.transform(for: CGSize(width: 100, height: 50))
        let p = CGPoint(x: 0, y: 0).applying(t)
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0, accuracy: 1e-9)
    }

    func testScaleIsAroundCentre() {
        var a = StereoAlignment.identity
        a.scale = 2
        let t = a.transform(for: CGSize(width: 100, height: 50))
        let centre = CGPoint(x: 50, y: 25).applying(t)
        XCTAssertEqual(centre.x, 50, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 25, accuracy: 1e-9)
    }
}
