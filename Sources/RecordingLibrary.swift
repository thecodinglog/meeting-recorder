import AppKit
import AVFoundation
import Combine

/// 목록·재생기를 메뉴바와 편집 창에서 공유한다. 창을 닫아도 재생 위치를 유지한다.
@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var items: [SavedRecording] = []
    @Published private(set) var selected: SavedRecording?
    @Published private(set) var transcripts: [SavedTranscript] = []
    private var completedTranscripts: [URL] = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var isLoading = false
    @Published var message: String?
    @Published var name = ""
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var isLoadingWaveform = false
    var onChange: ((SavedRecording, SavedRecording) -> Void)?

    @Published private(set) var baseFolder: URL
    private var stores: [URL: RecordingStore]
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var cleanupTimer: Timer?
    private var selectionGeneration = UUID()
    private var refreshGeneration = UUID()
    private var waveformTask: Task<Void, Never>?
    private var waveformRequested = false
    private var previewEnd: Double?
    private var scrubbing = false
    private var resumeAfterScrubbing = false
    private var resumePreviewEnd: Double?
    private let playbackMuted: Bool

    init(baseFolder: URL, folders: [URL]? = nil, automaticMaintenance: Bool = true, playbackMuted: Bool = false) {
        self.baseFolder = baseFolder.resolvingSymlinksInPath().standardizedFileURL
        self.playbackMuted = playbackMuted
        stores = [:]
        for root in folders ?? [baseFolder] {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            stores[root] = RecordingStore(baseFolder: root)
        }
        guard automaticMaintenance else { return }
        Task { await refresh(); await cleanup() }
        // 앱을 종료한 동안 만료된 ZIP은 다음 실행 때 정리한다.
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.cleanup() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        cleanupTimer?.invalidate()
        waveformTask?.cancel()
    }

    func refresh(select folder: URL? = nil) async {
        let generation = UUID()
        refreshGeneration = generation
        var found: [SavedRecording] = []
        for store in stores.values {
            do { found += try await store.list() }
            catch { audioLog.error("저장 폴더 조회 실패: \(error.localizedDescription, privacy: .public)") }
        }
        guard generation == refreshGeneration else { return }
        items = found.sorted { $0.createdAt > $1.createdAt }
        refreshTranscripts()
        let desired = (folder ?? selected?.folder)?.resolvingSymlinksInPath().standardizedFileURL
        if let item = items.first(where: { $0.folder == desired }) ?? items.first,
           selected != item || player == nil {
            await select(item)
        } else if items.isEmpty { unload(); selected = nil }
    }

    func refreshTranscripts(completed: URL? = nil) {
        if let completed { completedTranscripts.append(completed) }
        var seen = Set<URL>()
        let candidates = items.map { $0.folder.appendingPathComponent(Transcriber.transcriptName) } + completedTranscripts
        transcripts = candidates.compactMap { candidate -> SavedTranscript? in
            let url = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            let title = url.lastPathComponent == Transcriber.transcriptName
                ? (items.first { $0.folder == url.deletingLastPathComponent() }?.title ?? url.deletingLastPathComponent().lastPathComponent)
                : url.deletingPathExtension().lastPathComponent
            return SavedTranscript(url: url, title: title, modifiedAt: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt }
        completedTranscripts = completedTranscripts.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func changeStorage(to folder: URL, folders: [URL]) async {
        guard !isBusy else { return }
        pause()
        baseFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        for root in folders {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            if stores[root] == nil { stores[root] = RecordingStore(baseFolder: root) }
        }
        await refresh()
        await cleanup()
    }

    private func store(for recording: SavedRecording) throws -> RecordingStore {
        let root = recording.folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard let store = stores[root] else { throw RecordingError.invalid("이 녹음의 저장 위치를 찾지 못했습니다.") }
        return store
    }

    func select(_ item: SavedRecording) async {
        guard !isBusy else { return }
        unload()
        let generation = UUID()
        selectionGeneration = generation
        selected = item
        name = item.title
        isLoading = true
        message = nil
        do {
            let length = try await RecordingStore.duration(item.audio)
            guard generation == selectionGeneration else { return }
            duration = length
            trimStart = 0
            trimEnd = length
            let player = AVPlayer(url: item.audio)
            player.isMuted = playbackMuted
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) {
                [weak self, weak player] time in
                Task { @MainActor in
                    guard let self, self.player === player else { return }
                    if !self.scrubbing { self.position = min(max(time.seconds.isFinite ? time.seconds : 0, 0), self.duration) }
                    if let end = self.previewEnd, time.seconds >= end {
                        self.pause()
                        self.seek(to: end)
                    }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isPlaying = false; self?.previewEnd = nil }
            }
            if waveformRequested { startWaveform(item, duration: length, generation: generation) }
        } catch {
            guard generation == selectionGeneration else { return }
            message = "재생할 수 없습니다: \(error.localizedDescription)"
        }
        if generation == selectionGeneration { isLoading = false }
    }

    func requestWaveform() {
        waveformRequested = true
        guard waveformTask == nil, waveform.isEmpty, let selected, duration > 0 else { return }
        startWaveform(selected, duration: duration, generation: selectionGeneration)
    }

    func hideWaveform() {
        waveformRequested = false
        waveformTask?.cancel()
        waveformTask = nil
        isLoadingWaveform = false
    }

    private func startWaveform(_ item: SavedRecording, duration: Double, generation: UUID) {
        isLoadingWaveform = true
        waveformTask = Task { [weak self] in
            let peaks = try? await RecordingWaveform.load(item.audio, duration: duration)
            guard !Task.isCancelled, let self, self.selectionGeneration == generation else { return }
            self.waveform = peaks ?? []
            self.isLoadingWaveform = false
            self.waveformTask = nil
        }
    }

    func togglePlayback() {
        guard !isBusy, let player else { return }
        if isPlaying { pause(); return }
        previewEnd = nil
        if position >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() { player?.pause(); isPlaying = false; previewEnd = nil }

    func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        position = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to seconds: Double) {
        position = min(max(seconds, 0), duration)
        if !scrubbing { seek(to: position) }
    }

    func scrubbingChanged(_ editing: Bool) {
        if editing {
            resumeAfterScrubbing = isPlaying
            resumePreviewEnd = previewEnd
            pause()
            scrubbing = true
        } else {
            scrubbing = false
            seek(to: position)
            if resumeAfterScrubbing, resumePreviewEnd == nil || position < resumePreviewEnd! {
                previewEnd = resumePreviewEnd
                player?.play()
                isPlaying = true
            }
            resumeAfterScrubbing = false
            resumePreviewEnd = nil
        }
    }

    func previewSelection(fromCurrent: Bool = false) {
        guard validTrim, let player else { return }
        pause()
        let start = fromCurrent && position >= trimStart && position < trimEnd - 0.05 ? position : trimStart
        seek(to: start)
        previewEnd = trimEnd
        player.play()
        isPlaying = true
    }

    var validTrim: Bool {
        duration > 0 && trimStart.isFinite && trimEnd.isFinite && trimStart >= 0 &&
        trimEnd <= duration + 0.01 && trimEnd - trimStart >= 0.1
    }
    var canTrim: Bool { validTrim && (trimStart > 0.001 || trimEnd < duration - 0.001) }
    var hasOtherTracks: Bool {
        guard let selected else { return false }
        return RecordingStore.trackNames.contains { FileManager.default.fileExists(atPath: selected.folder.appendingPathComponent($0).path) }
    }

    func rename() async {
        guard let original = selected, !isBusy, name != original.title else { return }
        isBusy = true
        let previous = position
        unload()
        do {
            let updated = try await store(for: original).rename(original, to: name)
            isBusy = false
            onChange?(original, updated)
            await refresh(select: updated.folder)
            seek(to: previous)
            message = "녹음 이름을 바꿨습니다."
        } catch {
            isBusy = false
            await select(original)
            seek(to: previous)
            message = error.localizedDescription
        }
    }

    @discardableResult
    func trim(includingTracks: Bool) async -> Bool {
        guard let original = selected, !isBusy, canTrim else { return false }
        let start = trimStart, end = trimEnd
        isBusy = true
        unload()
        message = "원본을 백업하고 선택한 구간을 저장하고 있습니다…"
        do {
            let updated = try await store(for: original).trim(original, start: start, end: end, includingTracks: includingTracks)
            isBusy = false
            onChange?(original, updated)
            await refresh(select: updated.folder)
            message = includingTracks
                ? "전체와 개별 트랙을 함께 잘랐습니다. 기존 회의록을 포함한 원본은 백업에 30일간 보관됩니다."
                : "전체 파일만 잘랐습니다. 개별 트랙은 유지되며 원본은 백업에 30일간 보관됩니다."
            return true
        } catch {
            isBusy = false
            await select(original)
            trimStart = min(start, max(0, duration - 0.1))
            trimEnd = min(end, duration)
            message = "편집하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    func openBackups() {
        let root = selected?.folder.deletingLastPathComponent() ?? baseFolder
        let folder = root.appendingPathComponent("백업", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: root.path), root != RecordingStorage.defaultFolder {
                throw RecordingError.invalid("백업을 열 저장 위치를 찾지 못했습니다. 디스크 연결을 확인하세요.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { message = error.localizedDescription }
    }

    private func cleanup() async {
        for store in stores.values {
            do { try await store.cleanupBackups() }
            catch { audioLog.error("만료 백업 정리 실패: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func unload() {
        pause()
        selectionGeneration = UUID()
        waveformTask?.cancel()
        waveformTask = nil
        waveform = []
        isLoadingWaveform = false
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        position = 0
        duration = 0
        trimStart = 0
        trimEnd = 0
        isLoading = false
        scrubbing = false
        resumeAfterScrubbing = false
        resumePreviewEnd = nil
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let hours = Int(value) / 3_600, minutes = Int(value) / 60 % 60
        return hours > 0 ? String(format: "%d:%02d:%04.1f", hours, minutes, value.truncatingRemainder(dividingBy: 60))
            : String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}

struct SavedTranscript: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let modifiedAt: Date
}
