import Foundation
import Testing
@testable import MeetingRecorder

@MainActor
private final class FakeMicActivity: MicActivityMonitoring {
    var onChange: (() -> Void)?
    var isListening = false
    var registrationFails = false
    var requiresPolling: Bool { registrationFails || !isListening }
    var isAnyInputRunning = false
    var starts = 0

    func start() { starts += 1; isListening = true }
    func stop() { isListening = false }
    func change(running: Bool) {
        isAnyInputRunning = running
        onChange?()
    }
}

@MainActor
private final class FakeMicUsage: MicUsageQuerying {
    var users: [String] = []
    var queries = 0
    func inputBundleIDs(matching prefixes: [String]) -> [String] {
        queries += 1
        return users.filter { id in prefixes.contains { id.hasPrefix($0) } }
    }
}

@MainActor
private final class DetectionFixture {
    let defaults = UserDefaults(suiteName: "MeetingWatcherTests.\(UUID().uuidString)")!
    let activity = FakeMicActivity()
    let usage = FakeMicUsage()
    let watcher: MeetingWatcher
    private var settings = MeetingWatcher.defaults

    init() {
        // 일반 회의 감지만 검증한다. 전화 자동 녹음은 별도 테스트에서 다룬다.
        settings[MeetingWatcher.phoneAutoRecordKey] = false
        defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        watcher = MeetingWatcher(defaults: defaults, micActivity: activity, micUsage: usage)
    }

    func configure(_ values: [String: Any]) {
        settings.merge(values) { _, new in new }
        defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        watcher.updateDetection()
    }

    func stop() { configure([MeetingWatcher.enabledKey: false]) }
}

@Suite(.serialized)
@MainActor
struct MeetingWatcherTests {
    @Test func idleDoesNotPollOrQueryProcesses() async throws {
        let f = DetectionFixture()
        defer { f.stop() }
        f.watcher.updateDetection()
        #expect(f.activity.isListening)
        #expect(!f.watcher.isPolling)
        // 기존 폴링 주기보다 길게 기다려 예약된 조회도 없는지 확인한다.
        try await Task.sleep(for: .seconds(2.7))
        #expect(f.usage.queries == 0)
    }

    @Test func noSelectedAppsStopsAllAudioMonitoring() {
        let f = DetectionFixture()
        defer { f.stop() }
        f.activity.isAnyInputRunning = true
        f.configure(Dictionary(uniqueKeysWithValues: MeetingWatcher.apps.map { ($0.key, false as Any) }))
        #expect(!f.activity.isListening)
        #expect(!f.watcher.isPolling)
        #expect(f.activity.starts == 0)
        #expect(f.usage.queries == 0)
    }

    @Test func meetingStartAndEndKeepDebounceThenReturnToIdle() {
        let f = DetectionFixture()
        defer { f.stop() }
        f.watcher.updateDetection()
        f.usage.users = ["com.microsoft.teams.helper"]
        f.activity.change(running: true)
        #expect(f.watcher.isPolling)
        #expect(f.usage.queries == 1)
        #expect(f.watcher.activeApp == nil)
        f.watcher.poll()
        #expect(f.watcher.activeApp == "Microsoft Teams")

        f.usage.users = []
        f.activity.change(running: false)
        for _ in 0..<4 { f.watcher.poll() }
        #expect(f.watcher.activeApp == "Microsoft Teams")
        #expect(f.watcher.isPolling)
        f.watcher.poll()
        #expect(f.watcher.activeApp == nil)
        #expect(!f.watcher.isPolling)
    }

    @Test func briefMicUseDoesNotLeavePollingRunning() {
        let f = DetectionFixture()
        defer { f.stop() }
        f.watcher.updateDetection()
        f.usage.users = ["us.zoom.xos"]
        f.activity.change(running: true)
        f.usage.users = []
        f.activity.change(running: false)
        f.watcher.poll()
        #expect(f.watcher.activeApp == nil)
        #expect(!f.watcher.isPolling)
    }

    @Test func listenerFailureFallsBackToPolling() {
        let f = DetectionFixture()
        defer { f.stop() }
        f.activity.registrationFails = true
        f.watcher.updateDetection()
        #expect(f.watcher.isPolling)
        f.usage.users = ["us.zoom.xos"]
        f.watcher.poll()
        f.watcher.poll()
        #expect(f.watcher.activeApp == "Zoom")
    }

    @Test func disabledDetectionIgnoresLateAudioEvents() {
        let f = DetectionFixture()
        f.watcher.updateDetection()
        f.stop()
        f.activity.change(running: true)
        #expect(!f.activity.isListening)
        #expect(!f.watcher.isPolling)
        #expect(f.usage.queries == 0)
    }

    @Test func extraPrefixesRemainDetectableWithBuiltInAppsOff() {
        let f = DetectionFixture()
        defer { f.stop() }
        f.configure(Dictionary(uniqueKeysWithValues: MeetingWatcher.apps.map { ($0.key, false as Any) }))
        f.configure(["detectExtraPrefixes": ["example.meeting"]])
        #expect(f.activity.isListening)
        f.usage.users = ["example.meeting.helper"]
        f.activity.change(running: true)
        f.watcher.poll()
        #expect(f.watcher.activeApp == "테스트 앱")
    }
}
