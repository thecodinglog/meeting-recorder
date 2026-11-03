import AppKit
import Combine

/// 저장 위치와 이전에 사용한 위치를 기억한다. 기존 파일을 이동하지 않고 목록과 백업 정리를 유지한다.
@MainActor
final class RecordingStorage: ObservableObject {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("회의녹음", isDirectory: true)
    }
    static let preferenceKey = "recordingStorageLocations.v1"
    private struct Location: Codable {
        var path: String
        var bookmark: Data?
    }
    private struct Preferences: Codable {
        var current: Location
        var previous: [Location]
    }

    @Published private(set) var folder: URL
    @Published private(set) var folders: [URL]
    private let defaults: UserDefaults
    private let isolated: Bool

    init(defaults: UserDefaults = .standard, overrideFolder: URL? = nil) {
        self.defaults = defaults
        isolated = overrideFolder != nil
        if let overrideFolder {
            let root = overrideFolder.resolvingSymlinksInPath().standardizedFileURL
            folder = root
            folders = [root]
        } else if let data = defaults.data(forKey: Self.preferenceKey),
                  let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            let root = Self.resolve(saved.current)
            folder = root
            folders = Self.unique([root] + saved.previous.map(Self.resolve) + [Self.defaultFolder])
        } else {
            folder = Self.defaultFolder
            folders = [Self.defaultFolder]
        }
    }

    func use(_ proposed: URL) throws {
        let next = proposed.resolvingSymlinksInPath().standardizedFileURL
        try Self.validate(next, createIfMissing: next == Self.defaultFolder)
        if [RecordingInfo.fileName, "전체.m4a", "시스템.m4a", "마이크.m4a"].contains(where: {
            FileManager.default.fileExists(atPath: next.appendingPathComponent($0).path)
        }) {
            throw RecordingError.invalid("개별 녹음 폴더 대신 녹음들을 보관할 상위 폴더를 선택하세요.")
        }
        // 실제 쓰기 가능 여부도 확인한 뒤에만 선택값을 저장한다.
        let probe = next.appendingPathComponent(".meeting-recorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data().write(to: probe, options: .withoutOverwriting)
        let locations = Self.unique([next] + folders)
        if !isolated {
            let preferences = Preferences(current: Self.location(next), previous: locations.filter { $0 != next }.map(Self.location))
            try JSONEncoder().encode(preferences).write(to: probe, options: .atomic)
            defaults.set(try JSONEncoder().encode(preferences), forKey: Self.preferenceKey)
        }
        folder = next
        folders = locations
    }

    func prepareForRecording() throws {
        try Self.validate(folder, createIfMissing: folder == Self.defaultFolder || isolated)
    }

    private static func validate(_ folder: URL, createIfMissing: Bool) throws {
        let fm = FileManager.default
        var directory: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &directory), createIfMissing {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = true
        }
        guard fm.fileExists(atPath: folder.path), directory.boolValue else {
            throw RecordingError.invalid("저장 폴더를 찾지 못했습니다. 외장 디스크 연결을 확인하거나 설정에서 저장 위치를 다시 선택하세요.")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw RecordingError.invalid("선택한 폴더에 저장할 권한이 없습니다. 설정에서 쓰기 가능한 폴더를 선택하세요.")
        }
    }

    private static func location(_ folder: URL) -> Location {
        Location(path: folder.path, bookmark: try? folder.bookmarkData(options: .minimalBookmark,
                                                                     includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    private static func resolve(_ location: Location) -> URL {
        if let data = location.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return URL(fileURLWithPath: location.path, isDirectory: true).standardizedFileURL
    }
    private static func unique(_ folders: [URL]) -> [URL] {
        var seen = Set<String>()
        return folders.map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }
}
