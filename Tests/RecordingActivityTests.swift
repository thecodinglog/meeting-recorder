import Foundation
import Testing
@testable import MeetingRecorder

private final class ActivitySpy {
    var started: [ProcessInfo.ActivityOptions] = []
    var live: Set<ObjectIdentifier> = []
    var ended = 0

    func makeActivity() -> RecordingActivity {
        RecordingActivity(begin: { options in
            let token = NSObject()
            self.started.append(options)
            self.live.insert(ObjectIdentifier(token))
            return token
        }, end: { token in
            #expect(self.live.remove(ObjectIdentifier(token)) != nil)
            self.ended += 1
        })
    }
}

struct RecordingActivityTests {
    @Test func idleOrFailedStartDoesNotPreventSleep() {
        let spy = ActivitySpy()
        let activity = spy.makeActivity()
        activity.update(isRecording: false, preventSleep: true)
        activity.update(isRecording: false, preventSleep: false)
        #expect(!activity.isActive)
        #expect(spy.started.isEmpty)
    }

    @Test func liveToggleUpdatesBothSleepPoliciesAndReleasesOldActivity() {
        let spy = ActivitySpy()
        let activity = spy.makeActivity()
        activity.update(isRecording: true, preventSleep: false)
        #expect(!spy.started[0].contains(.idleSystemSleepDisabled))
        #expect(!spy.started[0].contains(.idleDisplaySleepDisabled))

        activity.update(isRecording: true, preventSleep: true)
        #expect(spy.started[1].contains(.idleSystemSleepDisabled))
        #expect(spy.started[1].contains(.idleDisplaySleepDisabled))
        #expect(spy.ended == 1)
        #expect(spy.live.count == 1)

        activity.update(isRecording: true, preventSleep: true)
        #expect(spy.started.count == 2)
        activity.update(isRecording: true, preventSleep: false)
        #expect(!spy.started[2].contains(.idleSystemSleepDisabled))
        #expect(!spy.started[2].contains(.idleDisplaySleepDisabled))
        #expect(spy.ended == 2)
        #expect(spy.live.count == 1)

        activity.update(isRecording: false, preventSleep: false)
        #expect(!activity.isActive)
        #expect(spy.live.isEmpty)
        #expect(spy.ended == 3)
    }

    @Test func repeatedRecordingsAndStopsDoNotLeakActivities() {
        let spy = ActivitySpy()
        let activity = spy.makeActivity()
        for _ in 0..<12 {
            activity.update(isRecording: true, preventSleep: true)
            activity.update(isRecording: true, preventSleep: true)
            #expect(spy.live.count == 1)
            activity.update(isRecording: false, preventSleep: true)
            activity.update(isRecording: false, preventSleep: true)
            #expect(spy.live.isEmpty)
        }
        #expect(spy.started.count == 12)
        #expect(spy.ended == 12)
    }

    @Test func deinitializationReleasesActiveProtection() {
        let spy = ActivitySpy()
        var activity: RecordingActivity? = spy.makeActivity()
        activity?.update(isRecording: true, preventSleep: true)
        #expect(spy.live.count == 1)
        activity = nil
        #expect(spy.live.isEmpty)
        #expect(spy.ended == 1)
    }
}
