import Foundation
import SwiftUI
import CoreMedia

enum Eye: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "左目 (Left)" : "右目 (Right)" }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case left = "左"
    case right = "右"
    case blend = "50%合成"
    case difference = "差分"
    case anaglyph = "アナグリフ"
    case sideBySide = "SBS"
    var id: String { rawValue }
}

enum ExportPhase: Equatable {
    case idle
    case running(progress: Double, message: String)
    case finished(URL)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class ProjectState: ObservableObject {
    @Published var left: VideoSource?
    @Published var right: VideoSource?

    /// Seconds to add to the right clip's time to reach the same instant as the left clip.
    /// i.e. `rightTime = leftTime + rightOffsetSeconds`.
    @Published var rightOffsetSeconds: Double = 0
    @Published var alignment = StereoAlignment()
    @Published var exportSettings = ExportSettings()

    @Published var previewMode: PreviewMode = .blend
    /// Preview position in seconds along the left clip's timeline.
    @Published var previewTime: Double = 0
    @Published var previewImage: CGImage?
    @Published var isRenderingPreview = false

    @Published var isSyncing = false
    @Published var syncMessage: String?
    @Published var exportPhase: ExportPhase = .idle
    @Published var errorMessage: String?

    private var exportTask: Task<Void, Never>?
    private let renderer = StereoFrameRenderer()

    var isReady: Bool { left != nil && right != nil }

    /// Duration of the overlapping region of both clips, measured on the left timeline.
    var overlapDuration: Double {
        guard let left, let right else { return 0 }
        let leftDur = left.duration.seconds
        let rightDur = right.duration.seconds
        let start = max(0, -rightOffsetSeconds)
        let end = min(leftDur, rightDur - rightOffsetSeconds)
        return max(0, end - start)
    }

    var overlapStart: Double { max(0, -rightOffsetSeconds) }

    var sourceSize: CGSize { left?.naturalSize ?? CGSize(width: 3840, height: 2160) }
    var sourceFrameRate: Double { Double(left?.nominalFrameRate ?? 30) }

    // MARK: Loading

    /// URLs from the open panel / drag-and-drop are security-scoped under the App Sandbox; access must stay
    /// open while the clip is loaded because preview and export read the file repeatedly.
    private var scopedAccess: [Eye: URL] = [:]

    private func endScopedAccess(for eye: Eye) {
        scopedAccess.removeValue(forKey: eye)?.stopAccessingSecurityScopedResource()
    }

    func load(url: URL, into eye: Eye) {
        Task {
            do {
                endScopedAccess(for: eye)
                if url.startAccessingSecurityScopedResource() { scopedAccess[eye] = url }
                let source = try await VideoSource.load(url: url)
                switch eye {
                case .left: left = source
                case .right: right = source
                }
                previewTime = overlapStart
                await autoSyncByTimecodeIfPossible()
                await refreshPreview()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clear(eye: Eye) {
        endScopedAccess(for: eye)
        switch eye {
        case .left: left = nil
        case .right: right = nil
        }
        previewImage = nil
    }

    // MARK: Sync

    func autoSyncByTimecodeIfPossible() async {
        guard let l = left?.startTimecodeSeconds, let r = right?.startTimecodeSeconds else { return }
        rightOffsetSeconds = l - r
        syncMessage = String(format: "タイムコードで同期: オフセット %.3f s", rightOffsetSeconds)
    }

    func syncByAudio() {
        guard let left, let right else { return }
        isSyncing = true
        syncMessage = "音声波形を解析中…"
        Task {
            do {
                let result = try await AudioSyncEstimator.estimateOffset(
                    reference: left.asset,
                    target: right.asset,
                    analysisDuration: 60
                )
                rightOffsetSeconds = result.offsetSeconds
                syncMessage = String(format: "音声で同期: オフセット %.3f s (信頼度 %.2f)", result.offsetSeconds, result.confidence)
                await refreshPreview()
            } catch {
                syncMessage = nil
                errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    // MARK: Preview

    private var previewRequestID = 0

    func refreshPreview() async {
        guard let left, let right else { return }
        previewRequestID += 1
        let requestID = previewRequestID
        isRenderingPreview = true
        defer { if requestID == previewRequestID { isRenderingPreview = false } }

        let leftTime = CMTime(seconds: previewTime, preferredTimescale: 600)
        let rightTime = CMTime(seconds: previewTime + rightOffsetSeconds, preferredTimescale: 600)
        do {
            let image = try await renderer.renderPreview(
                left: left.asset, leftTime: leftTime,
                right: right.asset, rightTime: rightTime,
                alignment: alignment,
                swapEyes: exportSettings.swapEyes,
                mode: previewMode,
                maxWidth: 1600
            )
            if requestID == previewRequestID {
                previewImage = image
            }
        } catch {
            if requestID == previewRequestID {
                errorMessage = error.localizedDescription
            }
        }
    }

    func schedulePreviewRefresh() {
        Task { await refreshPreview() }
    }

    // MARK: Export

    func export(to url: URL) {
        guard let left, let right else { return }
        exportPhase = .running(progress: 0, message: "準備中…")
        let job = SpatialExportJob(
            left: left,
            right: right,
            rightOffsetSeconds: rightOffsetSeconds,
            alignment: alignment,
            settings: exportSettings,
            outputURL: url
        )
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await SpatialVideoExporter.run(job: job) { [weak self] progress, message in
                    Task { @MainActor in
                        self?.exportPhase = .running(progress: progress, message: message)
                    }
                }
                await MainActor.run { [weak self] in self?.exportPhase = .finished(url) }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.exportPhase = .failed("キャンセルされました") }
            } catch {
                await MainActor.run { [weak self] in self?.exportPhase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}
