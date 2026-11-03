import AppKit
import SwiftUI

struct RecordingPlayerCard: View {
    @ObservedObject var library: RecordingLibrary
    let unavailable: Bool
    var editingUnavailable = false
    var compact = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBarPanel) private var dismissMenuBarPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("녹음 다시 듣기", systemImage: "waveform").font(.caption.bold()).foregroundStyle(Theme.blue)
                Spacer()
                if compact {
                    Button("목록·편집") {
                        dismissMenuBarPanel()
                        openWindow(id: "recordings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.blue)
                }
            }
            if library.selected != nil {
                HStack(spacing: 6) {
                    TextField("녹음 이름", text: $library.name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await library.rename() } }
                        .accessibilityLabel("녹음 파일 이름")
                    Button { Task { await library.rename() } } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
                    .help("입력한 이름으로 파일 이름 변경")
                    .disabled(library.name == library.selected?.title)
                }
                .disabled(unavailable || editingUnavailable || library.isBusy)
                HStack(spacing: 10) {
                    Button { library.togglePlayback() } label: {
                        Image(systemName: library.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: compact ? 30 : 40)).foregroundStyle(Theme.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(library.isPlaying ? "녹음 일시 정지" : "녹음 재생")
                    Slider(value: Binding(get: { library.position }, set: { library.scrub(to: $0) }),
                           in: 0...max(library.duration, 0.01), onEditingChanged: library.scrubbingChanged)
                        .accessibilityLabel("녹음 재생 위치")
                }
                .disabled(unavailable || library.isBusy || library.isLoading || library.duration <= 0)
                HStack {
                    Text(RecordingLibrary.time(library.position))
                    Spacer()
                    if library.isLoading { ProgressView().controlSize(.mini) }
                    Text(RecordingLibrary.time(library.duration))
                }
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("녹음이 끝나면 여기서 바로 재생할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if compact, let message = library.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 12 : 20)
        .card()
    }
}

struct RecordingsView: View {
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var recorder: Recorder
    @State private var confirmTrim = false
    @State private var editing = false
    private var unavailable: Bool { recorder.isRecording || recorder.isStarting || recorder.isSaving }

    init(library: RecordingLibrary, recorder: Recorder, initialEditing: Bool = false) {
        self.library = library
        self.recorder = recorder
        _editing = State(initialValue: initialEditing)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { library.selected?.id }, set: { id in
                    if let item = library.items.first(where: { $0.id == id }) { Task { await library.select(item) } }
                })) {
                    ForEach(library.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(item.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ko_KR"))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6).tag(item.id)
                    }
                }
                .disabled(library.isBusy)
                Divider()
                HStack {
                    Button { Task { await library.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("녹음 목록 새로 고침")
                    Spacer()
                    Button("백업 폴더") { library.openBackups() }
                }.padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RecordingEditor(library: library, editing: $editing, unavailable: unavailable,
                                        editingUnavailable: recorder.isTranscribing, apply: { confirmTrim = true })
                        if let selected = library.selected {
                            HStack {
                                Text(selected.audio.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button("이 녹음으로 회의록 만들기") { recorder.transcribe(selected.folder) }
                                    .disabled(unavailable || recorder.isTranscribing || library.isBusy || !Transcriber.isAvailable)
                            }
                            if selected.transcriptOutdated,
                               !FileManager.default.fileExists(atPath: selected.folder.appendingPathComponent(Transcriber.transcriptName).path) {
                                Text("개별 트랙을 편집한 녹음입니다. 회의록은 다시 작성해주세요.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if recorder.isTranscribing {
                            TranscriptionProgressView(source: recorder.transcribingSource?.lastPathComponent,
                                                      queuedCount: max(0, recorder.transcribingCount - 1))
                                .id("transcription-progress")
                        }
                        if let error = recorder.transcriptionError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        }
                        transcriptList.id("transcripts")
                        if let message = library.message {
                            Label(message, systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).card()
                        }
                        if unavailable || recorder.isTranscribing {
                            Text(unavailable ? "녹음이 끝나면 재생·이름 변경·편집을 사용할 수 있습니다." : "회의록 작성 중에도 재생할 수 있습니다. 이름 변경과 편집은 작성 후 가능합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("원본은 각 녹음의 저장 위치 아래 ‘백업’ 폴더에 ZIP으로 보관됩니다. 30일이 지난 백업은 앱 실행 시와 실행 중 6시간마다 자동 정리합니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: recorder.isTranscribing) { _, active in
                    if active { withAnimation { scroll.scrollTo("transcription-progress", anchor: .bottom) } }
                }
                .onChange(of: recorder.transcriptRevision) { _, _ in
                    withAnimation { scroll.scrollTo("transcripts", anchor: .top) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 630)
        .task { await library.refresh(); library.requestWaveform() }
        .onChange(of: library.selected?.id) { _, _ in editing = false; library.requestWaveform() }
        .onDisappear { library.hideWaveform() }
        .confirmationDialog("개별 트랙도 같은 구간으로 자를까요?", isPresented: $confirmTrim, titleVisibility: .visible) {
            if library.hasOtherTracks {
                Button("전체 + 시스템·마이크 함께 자르기") { applyTrim(includingTracks: true) }
            }
            Button("전체 파일만 자르기") { applyTrim(includingTracks: false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("남길 구간: \(RecordingLibrary.time(library.trimStart)) – \(RecordingLibrary.time(library.trimEnd)). 원본은 먼저 압축 백업하고 30일 동안 보관합니다. 개별 트랙도 자르면 기존 회의록은 백업에 보관하고 다시 작성해야 합니다.")
        }
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("회의록 목록", systemImage: "doc.text").font(.headline)
                Spacer()
                Text("\(library.transcripts.count)개").font(.caption).foregroundStyle(.secondary)
            }
            if library.transcripts.isEmpty {
                Text("회의록을 만들면 여기에 표시됩니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(library.transcripts) { transcript in
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").foregroundStyle(Theme.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcript.title).font(.callout.weight(.semibold)).lineLimit(2)
                        Text(transcript.modifiedAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ko_KR"))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("열기") { NSWorkspace.shared.open(transcript.url) }
                        .accessibilityLabel("\(transcript.title) 회의록 열기")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([transcript.url]) } label: {
                        Image(systemName: "folder")
                    }.help("회의록 저장 위치 보기")
                }
                if transcript.id != library.transcripts.last?.id { Divider() }
            }
        }
        .padding(16).card()
    }

    private func applyTrim(includingTracks: Bool) {
        Task {
            if await library.trim(includingTracks: includingTracks) { editing = false }
        }
    }
}

struct TranscriptionProgressView: View {
    let source: String?
    let queuedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("회의록 작성 중…", systemImage: "text.badge.plus")
                .font(.headline).foregroundStyle(Theme.blue)
            if let source { Text(source).font(.callout).lineLimit(2) }
            ProgressView().progressViewStyle(.linear).tint(Theme.blue)
                .accessibilityLabel("회의록 작성 중")
            Text(queuedCount > 0 ? "\(queuedCount)개가 차례를 기다립니다." : "완료되면 아래 회의록 목록에 표시됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).card()
    }
}
