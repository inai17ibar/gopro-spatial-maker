import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SourcesSection()
                    Divider()
                    SyncSection()
                    Divider()
                    AlignmentSection()
                    Divider()
                    ExportSection()
                }
                .padding()
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: 440)

            PreviewPane()
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("エラー", isPresented: Binding(
            get: { project.errorMessage != nil },
            set: { if !$0 { project.errorMessage = nil } }
        )) {
            Button("OK") { project.errorMessage = nil }
        } message: {
            Text(project.errorMessage ?? "")
        }
    }
}

// MARK: - Sources

struct SourcesSection: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. 入力").font(.headline)
            HStack(spacing: 8) {
                SourceDropZone(eye: .left, source: project.left)
                SourceDropZone(eye: .right, source: project.right)
            }
            Text("GoPro を横に並べたとき、撮影者から見て左側のカメラが左目です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SourceDropZone: View {
    @EnvironmentObject var project: ProjectState
    let eye: Eye
    let source: VideoSource?
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 6) {
            Text(eye.label).font(.subheadline.bold())
            if let source {
                Text(source.fileName).lineLimit(1).truncationMode(.middle).font(.caption)
                Text("\(Int(source.naturalSize.width))×\(Int(source.naturalSize.height)) @ \(source.nominalFrameRate, specifier: "%.2f") fps")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("TC: \(source.startTimecodeString ?? "なし")")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("クリア") { project.clear(eye: eye) }.controlSize(.small)
            } else {
                Image(systemName: "film.stack").font(.title).foregroundStyle(.secondary)
                Text("ドロップ / クリックで選択").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .contentShape(Rectangle())
        .onTapGesture { showImporter = true }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in project.load(url: url, into: eye) }
            }
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result {
                project.load(url: url, into: eye)
            }
        }
    }
}

// MARK: - Sync

struct SyncSection: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. 同期").font(.headline)
            HStack {
                Text("右のオフセット")
                TextField("秒", value: $project.rightOffsetSeconds, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { project.schedulePreviewRefresh() }
                Text("秒")
                Stepper("", value: $project.rightOffsetSeconds, step: 1.0 / max(project.sourceFrameRate, 1))
                    .labelsHidden()
                    .onChange(of: project.rightOffsetSeconds) { _, _ in project.schedulePreviewRefresh() }
            }
            HStack {
                Button("タイムコードで同期") { Task { await project.autoSyncByTimecodeIfPossible(); await project.refreshPreview() } }
                    .disabled(project.left?.startTimecodeSeconds == nil || project.right?.startTimecodeSeconds == nil)
                Button("音声で同期") { project.syncByAudio() }
                    .disabled(!project.isReady || project.isSyncing)
                if project.isSyncing { ProgressView().controlSize(.small) }
            }
            if let message = project.syncMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("右クリップの時刻 = 左クリップの時刻 + オフセット。重なり区間: \(project.overlapDuration, specifier: "%.1f") 秒")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Alignment

struct AlignmentSection: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("3. 位置合わせ（右目を補正）").font(.headline)
                Spacer()
                Button("リセット") {
                    project.alignment = .identity
                    project.schedulePreviewRefresh()
                }.controlSize(.small)
            }
            AlignmentSlider(title: "水平 (視差/コンバージェンス)", value: $project.alignment.horizontalShift, range: -0.1...0.1, format: "%.4f")
            AlignmentSlider(title: "垂直", value: $project.alignment.verticalShift, range: -0.1...0.1, format: "%.4f")
            AlignmentSlider(title: "回転 (度)", value: $project.alignment.rotationDegrees, range: -5...5, format: "%.2f")
            AlignmentSlider(title: "スケール", value: $project.alignment.scale, range: 0.9...1.1, format: "%.3f")
            AlignmentSlider(title: "明るさ", value: $project.alignment.brightness, range: -0.3...0.3, format: "%.3f")
            AlignmentSlider(title: "コントラスト", value: $project.alignment.contrast, range: 0.7...1.3, format: "%.3f")
            AlignmentSlider(title: "彩度", value: $project.alignment.saturation, range: 0.5...1.5, format: "%.3f")
            Toggle("左右を入れ替える", isOn: $project.exportSettings.swapEyes)
                .onChange(of: project.exportSettings.swapEyes) { _, _ in project.schedulePreviewRefresh() }
            Text("「差分」表示で縦ズレ・回転をゼロに近づけ、「アナグリフ」で主被写体の赤/シアンが重なるように水平を調整します。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AlignmentSlider: View {
    @EnvironmentObject var project: ProjectState
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                TextField("", value: $value, format: .number.precision(.fractionLength(4)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.caption.monospacedDigit())
                    .onSubmit { project.schedulePreviewRefresh() }
            }
            Slider(value: $value, in: range) { editing in
                if !editing { project.schedulePreviewRefresh() }
            }
        }
    }
}

// MARK: - Export

struct ExportSection: View {
    @EnvironmentObject var project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("4. 書き出し (MV-HEVC 空間ビデオ)").font(.headline)
            Picker("解像度 (片目)", selection: $project.exportSettings.resolution) {
                ForEach(OutputResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("フレームレート", selection: $project.exportSettings.frameRate) {
                ForEach(OutputFrameRate.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledNumberField(title: "ビットレート (Mbps/目)", value: $project.exportSettings.bitrateMbps)
            LabeledNumberField(title: "基線長 (mm)", value: $project.exportSettings.baselineMillimeters)
            LabeledNumberField(title: "水平画角 (度)", value: $project.exportSettings.horizontalFOVDegrees)
            HStack {
                Text("視差調整 (1/10000幅)")
                Spacer()
                TextField("", value: $project.exportSettings.disparityAdjustment, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
            }
            Toggle("音声を含める (左クリップから)", isOn: $project.exportSettings.includeAudio)

            switch project.exportPhase {
            case .idle, .finished, .failed:
                Button {
                    presentSavePanel()
                } label: {
                    Label("空間ビデオを書き出す…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!project.isReady || project.overlapDuration <= 0)
            case .running(let progress, let message):
                VStack(alignment: .leading) {
                    ProgressView(value: progress) { Text(message).font(.caption) }
                    Button("キャンセル") { project.cancelExport() }.controlSize(.small)
                }
            }

            if case .finished(let url) = project.exportPhase {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("完了: \(url.lastPathComponent)").font(.caption)
                    Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                }
                Text("AirDrop や iCloud で Apple Vision Pro に送ると、写真アプリで空間ビデオとして再生できます。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if case .failed(let message) = project.exportPhase {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        let base = project.left?.url.deletingPathExtension().lastPathComponent ?? "spatial"
        panel.nameFieldStringValue = "\(base)_spatial.mov"
        if panel.runModal() == .OK, let url = panel.url {
            project.export(to: url)
        }
    }
}

struct LabeledNumberField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
    }
}
