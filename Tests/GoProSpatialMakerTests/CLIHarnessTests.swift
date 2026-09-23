import XCTest
import AVFoundation
@testable import GoProSpatialMaker

/// Opt-in harness for exporting real files: set GSM_LEFT / GSM_RIGHT / GSM_OUT and run this test alone.
/// Skipped when the variables are absent so the normal suite stays self-contained.
final class CLIHarnessTests: XCTestCase {
    func testExportFromEnvironment() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let l = env["GSM_LEFT"], let r = env["GSM_RIGHT"], let o = env["GSM_OUT"] else {
            throw XCTSkip("GSM_LEFT / GSM_RIGHT / GSM_OUT not set")
        }
        let left = try await VideoSource.load(url: URL(fileURLWithPath: l))
        let right = try await VideoSource.load(url: URL(fileURLWithPath: r))

        let offset: Double
        if let lt = left.startTimecodeSeconds, let rt = right.startTimecodeSeconds {
            offset = lt - rt
            print("timecode offset = \(offset)")
        } else {
            offset = try await AudioSyncEstimator.estimateOffset(reference: left.asset, target: right.asset, analysisDuration: 30).offsetSeconds
            print("audio offset = \(offset)")
        }

        var settings = ExportSettings()
        settings.resolution = .source
        let job = SpatialExportJob(left: left, right: right, rightOffsetSeconds: offset,
                                   alignment: .identity, settings: settings, outputURL: URL(fileURLWithPath: o))
        try await SpatialVideoExporter.run(job: job) { p, msg in print(String(format: "%3.0f%% %@", p * 100, msg)) }
    }
}
