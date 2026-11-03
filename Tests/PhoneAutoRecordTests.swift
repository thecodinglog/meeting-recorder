import Foundation
import Testing
@testable import MeetingRecorder

@MainActor
private final class PhoneActivity: MicActivityMonitoring {
    var onChange: (() -> Void)?
    var isListening = false
    var requiresPolling = false
    var isAnyInputRunning = false
    func start() { isListening = true }
    func stop() { isListening = false }
    func change(_ running: Bool) { isAnyInputRunning = running; onChange?() }
}
@MainActor
private final class PhoneUsage: MicUsageQuerying {
    var users: [String] = []
    func inputBundleIDs(matching prefixes: [String]) -> [String] {
        users.filter { id in prefixes.contains { id.hasPrefix($0) } }
    }
}
@MainActor
private final class PhoneRecorder: MeetingRecordingControl {
    var isRecording = false
    var isStarting = false
    var isSaving = false
    var isEditing = false
    var starts = 0
    var stops = 0
    func start() { starts += 1; isRecording = true }
    func stop() { stops += 1; isRecording = false }
}

@MainActor
private final class PhoneFixture {
    let defaults = UserDefaults(suiteName: "PhoneTests.\(UUID().uuidString)")!
    let activity = PhoneActivity()
    let usage = PhoneUsage()
    let recorder = PhoneRecorder()
    let watcher: MeetingWatcher
    private var values: [String: Any]
    init(automatic: Bool? = nil, normalDetection: Bool = true) {
        values = MeetingWatcher.defaults
        if let automatic { values[MeetingWatcher.phoneAutoRecordKey] = automatic }
        values[MeetingWatcher.enabledKey] = normalDetection
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        watcher = MeetingWatcher(defaults: defaults, micActivity: activity, micUsage: usage)
        watcher.attach(recorder)
    }
    func phoneStarts() { usage.users = ["com.apple.mobilephone.audio"]; activity.change(true); watcher.poll() }
    func phoneEnds() { usage.users = []; activity.change(false); for _ in 0..<5 { watcher.poll() } }
    func cleanup() {
        values[MeetingWatcher.enabledKey] = false; values[MeetingWatcher.phoneAutoRecordKey] = false
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        watcher.updateDetection()
    }
}

@Suite(.serialized)
@MainActor
struct PhoneAutoRecordTests {
    @Test func defaultSettingsRecordAndStopPhoneCalls() {
        let f = PhoneFixture(); defer { f.cleanup() }
        f.phoneStarts()
        #expect(f.recorder.starts == 1)
        f.phoneEnds()
        #expect(f.recorder.stops == 1)
        #expect(!f.recorder.isRecording)
    }

    @Test func callEndStopsOwnedRecordingWithoutWaitingForPrompt() {
        let f = PhoneFixture(automatic: true); defer { f.cleanup() }
        f.phoneStarts()
        f.usage.users = []
        f.watcher.poll()
        #expect(f.recorder.isRecording) // 장치 전환일 수 있는 첫 끊김은 유지
        f.watcher.poll()
        #expect(!f.recorder.isRecording)
        #expect(f.recorder.stops == 1)
        #expect(f.watcher.activeApp == nil)
    }
    @Test func aBriefInputDropDoesNotStopTheCall() {
        let f = PhoneFixture(automatic: true); defer { f.cleanup() }
        f.phoneStarts()
        f.usage.users = []; f.watcher.poll()
        f.usage.users = ["com.apple.mobilephone.audio"]; f.watcher.poll()
        #expect(f.recorder.isRecording)
        #expect(f.recorder.stops == 0)
        f.recorder.stop()
    }
    @Test func callEndingDoesNotStopAnExistingManualRecording() {
        let f = PhoneFixture(automatic: true); defer { f.cleanup() }
        f.recorder.isRecording = true
        f.phoneStarts()
        f.usage.users = []; f.watcher.poll(); f.watcher.poll()
        #expect(f.recorder.isRecording)
        #expect(f.recorder.stops == 0)
        f.recorder.stop()
    }
    @Test func optInStartsWithoutDebounceAndManualStopIsRespected() {
        let f = PhoneFixture(automatic: true); defer { f.cleanup() }
        f.usage.users = ["com.apple.mobilephone.audio"]
        f.activity.change(true)
        #expect(f.recorder.starts == 1)
        f.recorder.stop()
        for _ in 0..<4 { f.watcher.poll() }
        #expect(f.recorder.starts == 1)
        // 종료 제안을 띄우지 않도록 정지한 상태에서 다음 통화를 재현한다.
        f.phoneEnds()
        f.phoneStarts()
        #expect(f.recorder.starts == 2)
        f.recorder.stop()
    }
    @Test func disabledOptionDoesNotRecordPhone() {
        let f = PhoneFixture(automatic: false); defer { f.cleanup() }
        f.phoneStarts()
        #expect(f.recorder.starts == 0)
    }
    @Test func phoneOptionWorksIndependentlyOfMeetingSuggestions() {
        let f = PhoneFixture(automatic: true, normalDetection: false); defer { f.cleanup() }
        f.phoneStarts()
        #expect(f.recorder.starts == 1)
        f.recorder.stop()
    }
    @Test func savingOrEditingDelaysStartWithoutDuplicatingIt() {
        let f = PhoneFixture(automatic: true); defer { f.cleanup() }
        f.recorder.isEditing = true
        f.phoneStarts()
        #expect(f.recorder.starts == 0)
        f.recorder.isEditing = false
        f.watcher.poll(); f.watcher.poll()
        #expect(f.recorder.starts == 1)
        f.recorder.stop()
    }
    @Test func ambiguousFaceTimeDaemonIsNotClassifiedAsPhone() {
        #expect(MicUsage.detectionID("com.apple.avconferenced", phoneRunning: true, faceTimeRunning: false) == "com.apple.mobilephone.audio")
        #expect(MicUsage.detectionID("com.apple.avconferenced", phoneRunning: true, faceTimeRunning: true) == "com.apple.avconferenced")
        #expect(MicUsage.detectionID("com.apple.avconferenced", phoneRunning: false, faceTimeRunning: false) == "com.apple.avconferenced")
        #expect(MicUsage.detectionID("com.apple.Siri", phoneRunning: true, faceTimeRunning: false) == "com.apple.Siri")
    }
}
