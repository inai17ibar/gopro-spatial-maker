import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("表示", selection: $project.previewMode) {
                    ForEach(PreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: project.previewMode) { _, _ in project.schedulePreviewRefresh() }
                if project.isRenderingPreview {
                    ProgressView().controlSize(.small)
                }
            }
            .padding([.horizontal, .top])

            ZStack {
                Color.black
                if let image = project.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(project.isReady ? "プレビューを生成中…" : "左右の動画を読み込んでください")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()

            HStack {
                Text(timeString(project.previewTime)).font(.caption.monospacedDigit())
                Slider(
                    value: $project.previewTime,
                    in: project.overlapStart...max(project.overlapStart + project.overlapDuration, project.overlapStart + 0.001)
                ) { editing in
                    if !editing { project.schedulePreviewRefresh() }
                }
                .disabled(!project.isReady)
                Text(timeString(project.overlapStart + project.overlapDuration)).font(.caption.monospacedDigit())
                Button {
                    project.previewTime = max(project.overlapStart, project.previewTime - 1 / max(project.sourceFrameRate, 1))
                    project.schedulePreviewRefresh()
                } label: { Image(systemName: "backward.frame") }
                Button {
                    project.previewTime = min(project.overlapStart + project.overlapDuration, project.previewTime + 1 / max(project.sourceFrameRate, 1))
                    project.schedulePreviewRefresh()
                } label: { Image(systemName: "forward.frame") }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds)
        let frac = Int((seconds - Double(total)) * 100)
        return String(format: "%02d:%02d.%02d", total / 60, total % 60, frac)
    }
}
