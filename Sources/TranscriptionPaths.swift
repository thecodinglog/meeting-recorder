import Foundation

/// Finder에서 실행해도 셸의 PATH나 소스 저장소 위치에 의존하지 않도록 경로를 정한다.
struct TranscriptionPaths {
    let whisperPath: String
    let modelsFolder: URL
    let pythonPath: String

    init(setting: (String) -> String? = { UserDefaults.standard.string(forKey: $0) },
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) {
        func configured(_ key: String) -> String? {
            guard let value = setting(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if value == "~" { return home.path }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))).path }
            return value
        }

        let whisperCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        whisperPath = configured("transcription.whisperPath")
            ?? whisperCandidates.first(where: isExecutable) ?? whisperCandidates[0]
        modelsFolder = URL(fileURLWithPath: configured("transcription.modelsFolder")
            ?? home.appendingPathComponent("models").path, isDirectory: true)

        let pythonCandidates = [
            home.appendingPathComponent("Library/Application Support/MeetingRecorder/venv/bin/python").path,
            // 기존 설치를 계속 쓸 수 있게 마지막 후보로만 남긴다.
            home.appendingPathComponent("projects/meeting-recorder/.venv/bin/python").path,
        ]
        pythonPath = configured("transcription.pythonPath")
            ?? pythonCandidates.first(where: isExecutable) ?? pythonCandidates[0]
    }
}
