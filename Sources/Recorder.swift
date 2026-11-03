import AVFoundation
import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

/// 메뉴바 상태와 녹음 시작·정지 흐름을 관리한다.
@MainActor
final class Recorder: ObservableObject, MeetingRecordingControl {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isSaving = false
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var message: String?
    @Published private(set) var needsPermission = false
    @Published private(set) var lastRecording: URL?
    @Published private(set) var recordingMicrophone = false
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var transcribingCount = 0
    @Published private(set) var lastTranscript: URL?
    @Published private(set) var transcriptRevision = UUID()
    @Published private(set) var transcribingSource: URL?
    @Published private(set) var transcriptionError: String?
    @Published var includeMicrophone = UserDefaults.standard.object(forKey: "includeMicrophone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeMicrophone, forKey: "includeMicrophone") }
    }
    // 기본은 꺼짐. 켜고 끈 값은 다음 실행에도 유지한다.
    @Published var autoTranscribe = UserDefaults.standard.bool(forKey: "autoTranscribe") {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published var preventSleepWhileRecording = UserDefaults.standard.object(forKey: "preventSleepWhileRecording") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(preventSleepWhileRecording, forKey: "preventSleepWhileRecording")
            recordingActivity.update(isRecording: isRecording, preventSleep: preventSleepWhileRecording)
        }
    }

    var isTranscribing: Bool { transcribingCount > 0 }
    var isEditing: Bool { library.isBusy }
    private var libraryUpdates: AnyCancellable?

    /// 점검용(--snapshot): 실제 녹음 없이 '녹음 중' 화면만 보여 준다.
    func previewRecordingState() {
        guard LaunchMode.isCheck else { return }
        isRecording = true
        recordingMicrophone = true
        elapsedText = "27:14"
        systemLevel = 0.58
        micLevel = 0.31
    }

    let watcher = MeetingWatcher()
    let library: RecordingLibrary
    let storage: RecordingStorage
    @Published private(set) var storageMessage: String?
    private var storageUpdates: AnyCancellable?

    private var capture: AudioCapture?
    private var sink: AudioSink?
    private var timer: Timer?
    private var startDate: Date?
    private let recordingActivity = RecordingActivity()
    private var rawSystemLevel: Float = 0
    private var rawMicLevel: Float = 0
    private var quitAfterSave = false
    private var isStopping = false
    private var stopAfterStart = false
    // 회의록 작업은 한 번에 하나만 돈다. whisper-cli(8스레드·1.6GB 모델)와 python(torch)을 여러 개 띄우지 않는다.
    private var transcribeChain: Task<Void, Never>?

    var baseFolder: URL { storage.folder }

    init(baseFolder: URL? = nil) {
        storage = RecordingStorage(overrideFolder: baseFolder ?? LifecycleCheck.outputFolder?.appendingPathComponent("recordings", isDirectory: true))
        library = RecordingLibrary(baseFolder: storage.folder, folders: storage.folders, automaticMaintenance: !LaunchMode.isCheck)
        libraryUpdates = library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        storageUpdates = storage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        library.onChange = { [weak self] original, updated in
            guard let self else { return }
            if self.lastRecording?.deletingLastPathComponent() == original.folder { self.lastRecording = updated.audio }
            if let transcript = self.lastTranscript, transcript.deletingLastPathComponent() == original.folder,
               !FileManager.default.fileExists(atPath: transcript.path) { self.lastTranscript = nil }
        }
        // 점검용: --selftest <초> 로 실행하면 그 시간만큼 녹음하고 저장한 뒤 종료한다.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let seconds = args.count > i + 1 ? Double(args[i + 1]) ?? 5 : 5
            Task {
                try? await Task.sleep(for: .seconds(1))
                start()
                try? await Task.sleep(for: .seconds(seconds + 1))
                quit()
            }
        }
        // 점검용: --transcribe <녹음 폴더> 로 실행하면 그 폴더의 회의록만 만들고 종료한다.
        if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
            quitAfterSave = true
            transcribe(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
        if !LaunchMode.isCheck || LaunchMode.isLifecycleCheck { watcher.attach(self) }
        LifecycleCheck.runIfRequested(self)
    }

    /// 녹음 폴더면 나/상대방으로, 음성·영상 파일이면 화자1·2…로 회의록을 만든다.
    /// 여러 개를 요청하면 앞 작업이 끝난 뒤 차례로 진행한다.
    func transcribe(_ url: URL) {
        guard !library.isBusy else { message = "편집 저장이 끝난 뒤 회의록을 작성하세요."; return }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        transcribingCount += 1
        transcriptionError = nil
        message = nil
        let previous = transcribeChain
        transcribeChain = Task {
            await previous?.value
            transcribingSource = url
            do {
                lastTranscript = isFolder
                    ? try await Transcriber.transcribe(folder: url)
                    : try await Transcriber.transcribe(file: url)
                library.refreshTranscripts(completed: lastTranscript)
                transcriptRevision = UUID()
            } catch {
                transcriptionError = "회의록 작성 실패: \(error.localizedDescription)"
                message = "회의록 작성 실패: \(error.localizedDescription)"
                audioLog.error("회의록 작성 실패: \(error.localizedDescription, privacy: .public)")
            }
            transcribingSource = nil
            transcribingCount -= 1
            if quitAfterSave, !isRecording, !isSaving, !isTranscribing { NSApp.terminate(nil) }
        }
    }

    func openLastTranscript() {
        if let lastTranscript { NSWorkspace.shared.open(lastTranscript) }
    }

    /// 최근 녹음 폴더. 아직 회의록이 없을 때만 돌려준다.
    var lastFolderWithoutTranscript: URL? {
        guard let folder = lastRecording?.deletingLastPathComponent() else { return nil }
        let transcript = folder.appendingPathComponent(Transcriber.transcriptName)
        return FileManager.default.fileExists(atPath: transcript.path) ? nil : folder
    }

    /// 녹음 폴더나 음성·영상 파일을 골라 회의록을 만든다. 이미 있으면 새로 만든다.
    func chooseAndTranscribe() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Transcriber.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = baseFolder
        panel.message = "회의록을 만들 녹음 폴더나 음성·영상 파일을 고르세요. 여러 개를 고를 수 있습니다."
        panel.prompt = "회의록 만들기"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { transcribe(url) }
    }

    func start() {
        guard !library.isBusy else { message = "편집 저장이 끝난 뒤 녹음을 시작하세요."; return }
        guard !isStarting, !isRecording, !isSaving else { return }
        library.pause()
        isStarting = true
        stopAfterStart = false
        message = nil
        needsPermission = false
        Task {
            await startCapture()
            isStarting = false
            if stopAfterStart, isRecording { stop() }
            if quitAfterSave, !isRecording, !isSaving, !isTranscribing { NSApp.terminate(nil) }
        }
    }

    func stop() {
        if isStarting, !isRecording {
            stopAfterStart = true
            return
        }
        guard isRecording, !isStopping, let sink else { return }
        isStopping = true
        Task {
            await capture?.stop()
            await finalize(sink)
        }
    }

    func quit() {
        if isStarting || isRecording {
            quitAfterSave = true
            stop()
        } else if isSaving || isTranscribing || library.isBusy {
            quitAfterSave = true
            message = "저장·편집과 회의록 작성이 끝나면 종료합니다."
            if library.isBusy {
                Task {
                    while library.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
                    if !isStarting, !isRecording, !isSaving, !isTranscribing { NSApp.terminate(nil) }
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func openFolder() {
        do { try storage.prepareForRecording(); NSWorkspace.shared.open(baseFolder) }
        catch { message = error.localizedDescription }
    }

    var canChangeStorage: Bool { !isStarting && !isRecording && !isSaving && !isTranscribing && !library.isBusy }

    func chooseStorageFolder() async {
        guard canChangeStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = baseFolder
        panel.message = "새 녹음과 백업을 저장할 폴더를 선택하세요. 기존 녹음은 이전 위치에서 계속 볼 수 있습니다."
        panel.prompt = "저장 위치로 사용"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        await changeStorage(to: folder)
    }

    func changeStorage(to folder: URL) async {
        guard canChangeStorage else { storageMessage = "녹음·저장·편집·회의록 작성이 끝난 뒤 위치를 변경하세요."; return }
        do {
            try storage.use(folder)
            await library.changeStorage(to: storage.folder, folders: storage.folders)
            storageMessage = "새 녹음부터 선택한 폴더에 저장합니다. 이전 녹음도 목록에서 계속 사용할 수 있습니다."
        } catch { storageMessage = "저장 위치를 변경하지 못했습니다: \(error.localizedDescription)" }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 녹음

    private func startCapture() async {
        do { try storage.prepareForRecording() }
        catch { fail(error.localizedDescription); return }
        let withMic = includeMicrophone
        if withMic, await !AVCaptureDevice.requestAccess(for: .audio) {
            fail("마이크 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용하세요.", permission: true)
            return
        }

        do {
            let folder = baseFolder.appendingPathComponent(Self.timestamp(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let sink = AudioSink(folder: folder)
            sink.onStop = { [weak self, weak sink] error in
                guard let sink else { return }
                Task { @MainActor in self?.captureDidStop(sink, error: error) }
            }
            let capture = AudioCapture(sink: sink)
            do {
                try await capture.start(withMicrophone: withMic)
            } catch {
                // 일부 입력만 열린 실패에서도 파일과 장치를 모두 닫는다.
                _ = await sink.finish()
                throw error
            }
            self.capture = capture
            self.sink = sink
            beginRecordingState(withMicrophone: withMic)
        } catch {
            fail("녹음을 시작하지 못했습니다: \(error.localizedDescription)", permission: true)
        }
    }

    private func captureDidStop(_ stoppedSink: AudioSink, error: Error) {
        guard isRecording, !isStopping, sink === stoppedSink else { return }
        message = "녹음이 중단되었습니다: \(error.localizedDescription)"
        stop()
    }

    private func finalize(_ sink: AudioSink) async {
        guard self.sink === sink else { return }
        capture = nil
        self.sink = nil
        isStopping = false
        endRecordingState()
        watcher.recordingStopped()
        isSaving = true

        let (tracks, errors) = await sink.finish()
        var notes = errors
        if tracks.isEmpty {
            notes.append("녹음된 소리가 없습니다.")
        } else if tracks.count == 1 {
            let output = sink.folder.appendingPathComponent("전체.m4a")
            do { try FileManager.default.copyItem(at: tracks[0].url, to: output); lastRecording = output }
            catch { lastRecording = tracks[0].url; notes.append("전체 파일 복사 실패: \(error.localizedDescription)") }
        } else {
            let output = sink.folder.appendingPathComponent("전체.m4a")
            do {
                try await Mixer.mix(tracks, to: output)
                lastRecording = output
            } catch {
                lastRecording = tracks[0].url
                notes.append("합치기에 실패해 트랙별 파일만 저장했습니다: \(error.localizedDescription)")
            }
        }
        if !notes.isEmpty {
            message = notes.joined(separator: "\n")
            audioLog.error("녹음 저장 결과: \(self.message ?? "", privacy: .public)")
        }
        audioLog.info("녹음 저장 완료: 트랙 \(tracks.count, privacy: .public)개")
        isSaving = false

        if !tracks.isEmpty {
            Transcriber.saveOffsets(tracks, in: sink.folder)
            if !LaunchMode.isCheck { await library.refresh(select: sink.folder) }
            // 자체 테스트는 회의록까지 확인하도록 항상 작성한다.
            if !LaunchMode.isLifecycleCheck, autoTranscribe || LaunchMode.isSelfTest { transcribe(sink.folder) }
        }
        if quitAfterSave, !isTranscribing { NSApp.terminate(nil) }
    }

    private func beginRecordingState(withMicrophone: Bool) {
        isRecording = true
        recordingMicrophone = withMicrophone
        startDate = Date()
        elapsedText = "00:00"
        recordingActivity.update(isRecording: true, preventSleep: preventSleepWhileRecording)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func endRecordingState() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        startDate = nil
        stopAfterStart = false
        recordingActivity.update(isRecording: false, preventSleep: preventSleepWhileRecording)
        systemLevel = 0
        micLevel = 0
        rawSystemLevel = 0
        rawMicLevel = 0
    }

    /// 반복 점검에서 캡처 객체가 실제로 해제됐는지 약한 참조로 확인한다.
    func captureResourceProbe() -> CaptureResourceProbe {
        CaptureResourceProbe(stream: capture, sink: sink)
    }

    var isCaptureIdle: Bool {
        !isStarting && !isStopping && !isRecording && !isSaving && capture == nil && sink == nil &&
        timer == nil && startDate == nil && !recordingActivity.isActive
    }

    private func tick() {
        guard let startDate else { return }
        let seconds = Int(Date().timeIntervalSince(startDate))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        let text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        if text != elapsedText { elapsedText = text }

        // 소리가 끊겨도 막대가 바로 떨어지지 않게 천천히 줄인다.
        if let levels = sink?.takeLevels() {
            rawSystemLevel = max(levels.system, rawSystemLevel * 0.6)
            rawMicLevel = max(levels.microphone, rawMicLevel * 0.6)
            // 메뉴바 아이콘은 바뀔 때마다 화면(모니터·Space)마다 다시 그려져 녹음 중 CPU의 절반을 썼다.
            // 막대를 8단계로 나눠 눈에 보이는 단계가 바뀔 때만 갱신한다.
            let system = (rawSystemLevel * 8).rounded() / 8
            let mic = (rawMicLevel * 8).rounded() / 8
            if system != systemLevel { systemLevel = system }
            if mic != micLevel { micLevel = mic }
        }
    }

    private func fail(_ text: String, permission: Bool = false) {
        message = text
        needsPermission = permission
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
