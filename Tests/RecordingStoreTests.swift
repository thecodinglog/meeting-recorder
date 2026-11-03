import AVFoundation
import Testing
@testable import MeetingRecorder

private struct RecordingFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingTests-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("2026-10-28_회의") }
    var store: RecordingStore { RecordingStore(baseFolder: root) }
    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.audio(folder.appendingPathComponent("전체.m4a"), seconds: 4)
        try Self.audio(folder.appendingPathComponent("시스템.m4a"), seconds: 3.5)
        try Self.audio(folder.appendingPathComponent("마이크.m4a"), seconds: 2.8)
        try JSONEncoder().encode(["시스템.m4a": 0.5, "마이크.m4a": 1.2])
            .write(to: folder.appendingPathComponent(".tracks.json"))
        try "원본 회의록".write(to: folder.appendingPathComponent("회의록.txt"), atomically: true, encoding: .utf8)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func item() throws -> SavedRecording { try RecordingStore.recording(in: folder) }
    func offsets() throws -> [String: Double] {
        try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: folder.appendingPathComponent(".tracks.json")))
    }
    static func audio(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000))!
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                             AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        try file.write(from: pcm)
    }
}

struct RecordingStoreTests {
    @Test @MainActor func transcriptListRefreshesAfterCreationAndRegenerationWithoutResettingPlayback() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let library = RecordingLibrary(baseFolder: f.root, automaticMaintenance: false, playbackMuted: true)
        await library.refresh()
        let transcript = f.folder.appendingPathComponent(Transcriber.transcriptName).resolvingSymlinksInPath().standardizedFileURL
        #expect(library.transcripts.map(\.url) == [transcript])
        library.seek(to: 1.5)
        let selected = library.selected
        let previousDate = try #require(library.transcripts.first?.modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: previousDate.addingTimeInterval(10)], ofItemAtPath: transcript.path)
        library.refreshTranscripts(completed: transcript)
        library.refreshTranscripts(completed: transcript)
        #expect(library.transcripts.count == 1)
        #expect(abs(try #require(library.transcripts.first?.modifiedAt).timeIntervalSince(previousDate) - 10) < 0.001)
        #expect(library.selected == selected)
        #expect(library.position == 1.5)
        library.name = "Renamed meeting"
        await library.rename()
        #expect(library.transcripts.first?.title == "Renamed meeting")
        let reopened = RecordingLibrary(baseFolder: f.root, automaticMaintenance: false, playbackMuted: true)
        await reopened.refresh()
        #expect(reopened.transcripts == library.transcripts)
        try FileManager.default.removeItem(at: transcript)
        library.refreshTranscripts()
        #expect(library.transcripts.isEmpty)
    }

    @Test @MainActor func transcriptListIncludesCompletedExternalFilesNewestFirst() throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let library = RecordingLibrary(baseFolder: f.root, automaticMaintenance: false)
        let older = f.root.appendingPathComponent("Older 회의록.txt")
        let newer = f.root.appendingPathComponent("Newer 회의록.txt")
        for (index, url) in [older, newer].enumerated() {
            try "Transcript".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: url.path)
            library.refreshTranscripts(completed: url)
        }
        #expect(library.transcripts.map(\.title) == ["Newer 회의록", "Older 회의록"])
        library.refreshTranscripts(completed: f.root)
        #expect(library.transcripts.count == 2)
    }

    @Test @MainActor func saveLocationPersistsAndUnavailableDiskDoesNotRecreateFolder() throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let suite = "RecordingStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = RecordingStorage(defaults: defaults)
        try storage.use(f.root)
        let restored = RecordingStorage(defaults: defaults)
        #expect(restored.folder == f.root.resolvingSymlinksInPath().standardizedFileURL)
        // 폴더가 아직 없는 새 환경에서는 심볼릭 링크 정리 후 끝의 /가 달라질 수 있다.
        let defaultFolder = RecordingStorage.defaultFolder.resolvingSymlinksInPath().standardizedFileURL
        #expect(restored.folders.contains(defaultFolder))
        let preference = defaults.data(forKey: RecordingStorage.preferenceKey)
        #expect(throws: (any Error).self) { try restored.use(f.folder) }
        #expect(defaults.data(forKey: RecordingStorage.preferenceKey) == preference)
        f.remove()
        #expect(throws: (any Error).self) { try restored.prepareForRecording() }
        #expect(!FileManager.default.fileExists(atPath: f.root.path))
    }

    @Test @MainActor func oldAndNewLocationsStayEditableWithSeparateBackups() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let newRoot = f.root.appendingPathComponent("다른 저장 위치")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let newRecording = newRoot.appendingPathComponent("두번째 회의")
        try FileManager.default.copyItem(at: f.folder, to: newRecording)
        let library = RecordingLibrary(baseFolder: f.root, automaticMaintenance: false, playbackMuted: true)
        await library.refresh(select: f.folder)
        await library.changeStorage(to: newRoot, folders: [f.root, newRoot])
        #expect(library.items.count == 2)
        #expect(library.selected?.folder == f.folder.resolvingSymlinksInPath().standardizedFileURL)
        library.name = "이전 위치 회의"
        await library.rename()
        #expect(library.selected?.title == "이전 위치 회의")
        library.trimStart = 0.5; library.trimEnd = 2.5
        let oldSuccess = await library.trim(includingTracks: false)
        #expect(oldSuccess)
        let newItem = try #require(library.items.first { $0.folder == newRecording.resolvingSymlinksInPath().standardizedFileURL })
        await library.select(newItem)
        library.trimStart = 1; library.trimEnd = 3
        let newSuccess = await library.trim(includingTracks: true)
        #expect(newSuccess)
        for root in [f.root, newRoot] {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("백업").path)
            #expect(names.filter { $0.hasSuffix(".zip") }.count == 1)
        }
        library.hideWaveform()
    }

    @Test func waveformUsesRealSamplesAndSupportsCancellation() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let peaks = try await RecordingWaveform.load(f.folder.appendingPathComponent("전체.m4a"), duration: 4, bins: 64)
        #expect(peaks.count == 64)
        #expect(peaks.filter { $0 > 0.1 }.count > 50)
        #expect(peaks.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        let job = Task { try await RecordingWaveform.load(f.folder.appendingPathComponent("전체.m4a"), duration: 4) }
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
    }

    @Test func trimHandlesClampToTimelineAndCannotCross() {
        #expect(TrimTimelineMath.time(at: 14, width: 1_028, duration: 50) == 0)
        #expect(TrimTimelineMath.time(at: 1_014, width: 1_028, duration: 50) == 50)
        #expect(TrimTimelineMath.time(at: -400, width: 1_028, duration: 50) == 0)
        #expect(TrimTimelineMath.time(at: 9_000, width: 1_028, duration: 50) == 50)
        #expect(TrimTimelineMath.time(at: 514, width: 1_028, duration: 50) == 25)
        #expect(abs(TrimTimelineMath.start(25, end: 20, duration: 50) - 19.9) < 0.001)
        #expect(abs(TrimTimelineMath.end(5, start: 10, duration: 50) - 10.1) < 0.001)
        #expect(TrimTimelineMath.start(-2, end: 20, duration: 50) == 0)
        #expect(TrimTimelineMath.end(90, start: 20, duration: 50) == 50)
    }

    @Test @MainActor func playerSupportsPlaybackScrubbingAndRangePreview() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let library = RecordingLibrary(baseFolder: f.root, automaticMaintenance: false, playbackMuted: true)
        await library.refresh()
        #expect(library.selected != nil)
        #expect(library.duration > 3.9)
        library.seek(to: 1)
        library.togglePlayback()
        // Bluetooth 출력의 첫 재생 준비도 기다린다. 재생 시계가 실제로 진행해야 한다.
        for _ in 0..<30 where library.position <= 1.2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(library.position > 1.2)
        library.scrubbingChanged(true)
        library.scrub(to: 2.5)
        library.scrubbingChanged(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.position >= 2.5 && library.position < 3.5)
        library.pause()
        #expect(!library.isPlaying)
        library.trimStart = 0.4; library.trimEnd = 0.8
        library.previewSelection()
        library.scrubbingChanged(true)
        library.scrub(to: 0.6)
        library.scrubbingChanged(false)
        try await Task.sleep(for: .seconds(1))
        #expect(!library.isPlaying)
        #expect(abs(library.position - 0.8) < 0.15)
        library.pause()
    }

    @Test func trimTogetherRespectsOffsetsAndPreservesCompleteOriginalInZIP() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let before = try Data(contentsOf: f.folder.appendingPathComponent("전체.m4a"))
        let item = try await f.store.trim(f.item(), start: 1, end: 3, includingTracks: true)
        #expect(abs(try await RecordingStore.duration(item.audio) - 2) < 0.07)
        #expect(abs(try await RecordingStore.duration(f.folder.appendingPathComponent("시스템.m4a")) - 2) < 0.07)
        #expect(abs(try await RecordingStore.duration(f.folder.appendingPathComponent("마이크.m4a")) - 1.8) < 0.07)
        let offsets = try f.offsets()
        #expect(abs(offsets["시스템.m4a"]! - 0) < 0.001)
        #expect(abs(offsets["마이크.m4a"]! - 0.2) < 0.001)
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("회의록.txt").path))
        #expect(item.transcriptOutdated)
        let backup = f.root.appendingPathComponent("백업")
        let zip = try #require(FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "zip" })
        let restore = f.root.appendingPathComponent("복원")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, restore.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let restored = restore.appendingPathComponent(f.folder.lastPathComponent)
        #expect(try Data(contentsOf: restored.appendingPathComponent("전체.m4a")) == before)
        #expect(try String(contentsOf: restored.appendingPathComponent("회의록.txt"), encoding: .utf8) == "원본 회의록")
    }

    @Test func repeatedMainOnlyEditsKeepTracksUntilLaterJointTrim() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let microphone = f.folder.appendingPathComponent("마이크.m4a")
        let original = try Data(contentsOf: microphone)
        let store = f.store
        var item = try await store.trim(f.item(), start: 1, end: 4, includingTracks: false)
        #expect(item.mainOffset == 1)
        item = try await store.trim(item, start: 0.5, end: 2.5, includingTracks: false)
        #expect(item.mainOffset == 1.5)
        #expect(try Data(contentsOf: microphone) == original)
        #expect(try f.offsets()["마이크.m4a"] == 1.2)
        item = try await store.trim(item, start: 0.3, end: 1.3, includingTracks: true)
        #expect(item.mainOffset == 0)
        #expect(try f.offsets()["마이크.m4a"] == 0)
        #expect(abs(try await RecordingStore.duration(microphone) - 1) < 0.07)
    }

    @Test func noOverlapRemovesTrackOnlyAfterBackup() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        _ = try await f.store.trim(f.item(), start: 0, end: 0.4, includingTracks: true)
        #expect(try f.offsets().isEmpty)
        for name in RecordingStore.trackNames { #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent(name).path)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("백업").path)
        #expect(files.contains { $0.hasSuffix(".zip") })
    }

    @Test func failedBackupLeavesEveryOriginalByteUnchanged() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let source = f.folder.appendingPathComponent("전체.m4a")
        let original = try Data(contentsOf: source)
        try Data([1]).write(to: f.root.appendingPathComponent("백업"))
        await #expect(throws: (any Error).self) {
            _ = try await f.store.trim(f.item(), start: 1, end: 2, includingTracks: true)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try String(contentsOf: f.folder.appendingPathComponent("회의록.txt"), encoding: .utf8) == "원본 회의록")
    }

    @Test func renameChangesActualAudioFileAndSurvivesReload() async throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let store = f.store
        let item = try await store.rename(f.item(), to: "신사업 기획 회의.m4a")
        #expect(item.title == "신사업 기획 회의")
        #expect(item.audio.lastPathComponent == "신사업 기획 회의.m4a")
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("전체.m4a").path))
        let reloaded = try await store.list().first
        #expect(reloaded == item)
        #expect(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("마이크.m4a").path))
        for invalid in ["../바깥", "", "시스템", "마이크", "bad/name", ".숨김"] {
            await #expect(throws: (any Error).self) { _ = try await store.rename(item, to: invalid) }
        }
        #expect(try await store.list().first == item)
    }

    @Test func thirtyDayRetentionUsesManifestDateAndIgnoresUnownedFiles() throws {
        let f = try RecordingFixture(); defer { f.remove() }
        let backups = RecordingBackups(folder: f.root.appendingPathComponent("백업"))
        let now = Date()
        let old = try backups.create(for: f.folder, now: now.addingTimeInterval(-30 * 86_400))
        let recent = try backups.create(for: f.folder, now: now.addingTimeInterval(-29 * 86_400))
        let unrelated = backups.folder.appendingPathComponent("개인백업.zip")
        try Data([1, 2, 3]).write(to: unrelated)
        // 파일을 열어 날짜가 갱신되어도 보관 기간은 백업 생성 시각 기준이다.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: old.path)
        #expect(try backups.removeExpired(now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try backups.removeExpired(now: now) == 0)
    }
}
