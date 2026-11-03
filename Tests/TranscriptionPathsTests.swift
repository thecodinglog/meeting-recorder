import Foundation
import Testing
@testable import MeetingRecorder

struct TranscriptionPathsTests {
    @Test func freshInstallDoesNotRequireSourceCheckout() {
        let paths = TranscriptionPaths(setting: { _ in nil }, home: URL(fileURLWithPath: "/example/home"),
                                       isExecutable: { _ in false })
        #expect(paths.pythonPath == "/example/home/Library/Application Support/MeetingRecorder/venv/bin/python")
        #expect(paths.modelsFolder.path == "/example/home/models")
    }

    @Test func intelHomebrewAndLegacyPythonRemainUsable() {
        let paths = TranscriptionPaths(setting: { _ in nil }, home: URL(fileURLWithPath: "/example/home"),
                                       isExecutable: { $0.hasPrefix("/usr/local/") || $0.contains("/.venv/") })
        #expect(paths.whisperPath == "/usr/local/bin/whisper-cli")
        #expect(paths.pythonPath == "/example/home/projects/meeting-recorder/.venv/bin/python")
    }

    @Test func explicitPathsWithSpacesOverrideAutomaticDiscovery() {
        let preferences = [
            "transcription.whisperPath": "/custom tools/whisper-cli",
            "transcription.modelsFolder": "~/custom models",
            "transcription.pythonPath": "/custom tools/venv/bin/python",
        ]
        let paths = TranscriptionPaths(setting: { preferences[$0] }, home: URL(fileURLWithPath: "/example/home"),
                                       isExecutable: { _ in false })
        #expect(paths.whisperPath == "/custom tools/whisper-cli")
        #expect(paths.modelsFolder.path == "/example/home/custom models")
        #expect(paths.pythonPath == "/custom tools/venv/bin/python")
    }

    @Test func preferredInstallationWinsWhenBothExist() {
        let paths = TranscriptionPaths(setting: { _ in nil }, home: URL(fileURLWithPath: "/example/home"),
                                       isExecutable: { _ in true })
        #expect(paths.whisperPath == "/opt/homebrew/bin/whisper-cli")
        #expect(paths.pythonPath.contains("/Application Support/"))
    }
}
