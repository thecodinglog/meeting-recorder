import AVFoundation
import Darwin

struct SavedRecording: Identifiable, Equatable, Sendable {
    var id: URL { folder }
    let folder: URL
    let title: String
    let audio: URL
    let createdAt: Date
    let mainOffset: Double
    let transcriptOutdated: Bool
}

struct RecordingInfo: Codable {
    var title: String
    var audioFile: String
    var createdAt: Date
    var mainOffset: Double = 0
    var transcriptOutdated = false
    static let fileName = ".recording.json"
}

enum RecordingError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

/// 이 앱이 만든 ZIP과 명세만 관리한다. 다른 ZIP이나 녹음 원본은 만료 정리 대상이 아니다.
struct RecordingBackups {
    let folder: URL
    struct Entry: Codable {
        var version = 1
        let id: UUID
        let createdAt: Date
        let originalFolder: String
        var archiveName: String { "\(id.uuidString).zip" }
    }

    func create(for source: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try validateBackupFolder()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = Entry(id: UUID(), createdAt: now, originalFolder: source.lastPathComponent)
        let partial = folder.appendingPathComponent(".\(entry.id.uuidString).partial.zip")
        defer { try? fm.removeItem(at: partial) }
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, partial.path])
        try run("/usr/bin/unzip", ["-tq", partial.path])
        let archive = folder.appendingPathComponent(entry.archiveName)
        try fm.moveItem(at: partial, to: archive)
        // 명세 저장이 실패해도 ZIP은 남긴다. 원본 교체는 아직 실행하지 않았다.
        try JSONEncoder().encode(entry).write(to: manifest(entry.id), options: .atomic)
        return archive
    }

    @discardableResult
    func removeExpired(now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        try validateBackupFolder()
        let limit = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var removed = 0
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard file.lastPathComponent.hasSuffix(".backup.json"),
                  (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.version == 1, file.lastPathComponent == manifest(entry.id).lastPathComponent,
                  entry.createdAt <= limit else { continue }
            let archive = folder.appendingPathComponent(entry.archiveName)
            if fm.fileExists(atPath: archive.path) { try fm.removeItem(at: archive) }
            try fm.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    private func manifest(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).backup.json") }

    private func validateBackupFolder() throws {
        if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecordingError.invalid("백업 폴더가 다른 위치로 연결되어 있습니다. 회의녹음 안에 실제 백업 폴더가 필요합니다.")
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecordingError.invalid("원본 압축 백업을 만들거나 검증하지 못했습니다. 원본은 변경하지 않았습니다.")
        }
    }
}

actor RecordingStore {
    let baseFolder: URL
    private var editing = Set<URL>()
    static let trackNames = ["시스템.m4a", "마이크.m4a"]
    init(baseFolder: URL) { self.baseFolder = baseFolder.resolvingSymlinksInPath().standardizedFileURL }
    var backups: RecordingBackups { RecordingBackups(folder: baseFolder.appendingPathComponent("백업", isDirectory: true)) }

    func list() throws -> [SavedRecording] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseFolder.path) else { return [] }
        return try fm.contentsOfDirectory(at: baseFolder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                          options: [.skipsHiddenFiles]).compactMap { folder in
            guard folder.lastPathComponent != "백업",
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return try? Self.recording(in: folder)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func recording(in sourceFolder: URL) throws -> SavedRecording {
        let folder = sourceFolder.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let info = (try? Data(contentsOf: folder.appendingPathComponent(RecordingInfo.fileName)))
            .flatMap { try? JSONDecoder().decode(RecordingInfo.self, from: $0) }
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let audio = info.flatMap { info -> URL? in
            guard URL(fileURLWithPath: info.audioFile).lastPathComponent == info.audioFile else { return nil }
            let file = folder.appendingPathComponent(info.audioFile)
            return fm.fileExists(atPath: file.path) ? file : nil
        } ?? files.first { $0.lastPathComponent == "전체.m4a" }
            ?? files.first { $0.pathExtension.lowercased() == "m4a" && !trackNames.contains($0.lastPathComponent) }
            ?? files.first { trackNames.contains($0.lastPathComponent) }
        guard let audio else { throw RecordingError.invalid("재생할 녹음 파일이 없습니다.") }
        let created = info?.createdAt ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
        return SavedRecording(folder: folder, title: info?.title ?? folder.lastPathComponent,
                              audio: audio, createdAt: created, mainOffset: info?.mainOffset ?? 0,
                              transcriptOutdated: info?.transcriptOutdated ?? false)
    }

    func rename(_ recording: SavedRecording, to proposed: String) throws -> SavedRecording {
        try validateFolder(recording.folder)
        guard !editing.contains(recording.folder) else { throw RecordingError.invalid("편집을 마친 뒤 이름을 바꿔주세요.") }
        let title = try Self.validTitle(proposed)
        let target = recording.folder.appendingPathComponent("\(title).m4a")
        guard !Self.trackNames.contains(target.lastPathComponent) else {
            throw RecordingError.invalid("시스템·마이크는 트랙 이름으로 사용 중입니다. 다른 이름을 입력하세요.")
        }
        let fm = FileManager.default
        if target != recording.audio, fm.fileExists(atPath: target.path) {
            throw RecordingError.invalid("같은 이름의 파일이 이미 있습니다.")
        }
        let preservesTrack = Self.trackNames.contains(recording.audio.lastPathComponent)
        if target != recording.audio {
            if preservesTrack { try fm.copyItem(at: recording.audio, to: target) }
            else { try fm.moveItem(at: recording.audio, to: target) }
        }
        do {
            try writeInfo(for: recording, title: title, audioFile: target.lastPathComponent, in: recording.folder)
        } catch {
            if target != recording.audio {
                if preservesTrack { try? fm.removeItem(at: target) }
                else { try? fm.moveItem(at: target, to: recording.audio) }
            }
            throw error
        }
        return try Self.recording(in: recording.folder)
    }

    static func validTitle(_ proposed: String) throws -> String {
        var title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".m4a") { title = String(title.dropLast(4)) }
        guard !title.isEmpty, !title.hasPrefix("."), title.utf8.count <= 180,
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil else {
            throw RecordingError.invalid("이름은 180바이트 이내로 입력하고 / : \\ 문자는 빼주세요.")
        }
        return title
    }

    /// 선택 구간은 '전체' 시간축이다. 전체만 여러 번 잘라도 mainOffset으로 원본 트랙과 연결한다.
    func trim(_ recording: SavedRecording, start: Double, end: Double, includingTracks: Bool) async throws -> SavedRecording {
        try validateFolder(recording.folder)
        guard editing.insert(recording.folder).inserted else { throw RecordingError.invalid("이미 편집 중인 녹음입니다.") }
        defer { editing.remove(recording.folder) }
        let duration = try await Self.duration(recording.audio)
        guard start.isFinite, end.isFinite, start >= 0, end <= duration + 0.02, end - start >= 0.1 else {
            throw RecordingError.invalid("남길 구간을 0.1초 이상 선택하세요.")
        }
        let fm = FileManager.default
        let stage = baseFolder.appendingPathComponent(".편집-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: recording.folder, to: stage)
        // 한 트랙뿐인 예전 녹음도 개별 트랙을 보존하면서 '전체' 편집본을 만든다.
        let mainName = Self.trackNames.contains(recording.audio.lastPathComponent) ? "전체.m4a" : recording.audio.lastPathComponent
        let mainOutput = stage.appendingPathComponent(".전체-\(UUID().uuidString).m4a")
        try await Self.export(recording.audio, start: start, end: min(end, duration), to: mainOutput)
        let destination = stage.appendingPathComponent(mainName)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: mainOutput, to: destination)

        if includingTracks {
            let offsetsFile = recording.folder.appendingPathComponent(".tracks.json")
            let offsets = (try? Data(contentsOf: offsetsFile))
                .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
            var updated: [String: Double] = [:]
            let absoluteStart = recording.mainOffset + start, absoluteEnd = recording.mainOffset + end
            for name in Self.trackNames {
                let source = recording.folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let length = try await Self.duration(source)
                let offset = offsets[name] ?? 0
                guard offset.isFinite, offset >= 0 else { throw RecordingError.invalid("트랙의 시작 시각 정보가 올바르지 않습니다.") }
                let begin = max(absoluteStart, offset), finish = min(absoluteEnd, offset + length)
                let target = stage.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                // 남길 구간에 전혀 없는 트랙은 편집본에서 빼고 압축 원본에 보관한다.
                if finish - begin > 0.001 {
                    try await Self.export(source, start: begin - offset, end: finish - offset, to: target)
                    updated[name] = begin - absoluteStart
                }
            }
            try JSONEncoder().encode(updated).write(to: stage.appendingPathComponent(".tracks.json"), options: .atomic)
            let transcript = stage.appendingPathComponent(Transcriber.transcriptName)
            if fm.fileExists(atPath: transcript.path) { try fm.removeItem(at: transcript) }
        }
        try writeInfo(for: recording, title: recording.title, audioFile: mainName, in: stage,
                      offset: includingTracks ? 0 : recording.mainOffset + start,
                      outdated: recording.transcriptOutdated || includingTracks)
        // 백업 생성과 무결성 검사가 성공해야만 원본 폴더와 편집본을 원자적으로 교환한다.
        _ = try backups.create(for: recording.folder)
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, recording.folder.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try Self.recording(in: recording.folder)
    }

    func cleanupBackups(now: Date = Date()) throws { try backups.removeExpired(now: now) }

    static func duration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw RecordingError.invalid("오디오 트랙을 읽지 못했습니다.")
        }
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw RecordingError.invalid("녹음 길이를 읽지 못했습니다.") }
        return seconds
    }

    private static func export(_ input: URL, start: Double, end: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.m4a) else {
            throw RecordingError.invalid("이 녹음은 음질을 유지한 채 자를 수 없습니다. 원본은 변경하지 않았습니다.")
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                        end: CMTime(seconds: end, preferredTimescale: 48_000))
        try await session.export(to: output, as: .m4a)
        _ = try await duration(output)
    }

    private func validateFolder(_ folder: URL) throws {
        let root = baseFolder.resolvingSymlinksInPath().standardizedFileURL
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == root,
              folder.lastPathComponent != "백업", !folder.lastPathComponent.hasPrefix(".") else {
            throw RecordingError.invalid("회의녹음 안의 녹음 폴더만 편집할 수 있습니다.")
        }
    }

    private func writeInfo(for recording: SavedRecording, title: String, audioFile: String, in folder: URL,
                           offset: Double? = nil, outdated: Bool? = nil) throws {
        let info = RecordingInfo(title: title, audioFile: audioFile, createdAt: recording.createdAt,
                                 mainOffset: offset ?? recording.mainOffset,
                                 transcriptOutdated: outdated ?? recording.transcriptOutdated)
        try JSONEncoder().encode(info).write(to: folder.appendingPathComponent(RecordingInfo.fileName), options: .atomic)
    }
}
