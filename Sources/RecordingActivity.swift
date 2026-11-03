import Foundation

/// 녹음 중에만 활동을 유지하고, 설정 변경·정지 시 기존 활동을 해제한다.
final class RecordingActivity {
    private let begin: (ProcessInfo.ActivityOptions) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?
    private var options: ProcessInfo.ActivityOptions?

    var isActive: Bool { token != nil }

    init(
        begin: @escaping (ProcessInfo.ActivityOptions) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: "회의 녹음 중")
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    func update(isRecording: Bool, preventSleep: Bool) {
        let next: ProcessInfo.ActivityOptions? = isRecording
            ? (preventSleep ? [.userInitiated, .idleDisplaySleepDisabled] : .userInitiatedAllowingIdleSystemSleep)
            : nil
        guard next != options else { return }
        // 설정 변경 중에도 녹음 활동이 끊기지 않도록 새 활동을 먼저 시작한다.
        let previous = token
        token = next.map(begin)
        options = next
        if let previous { end(previous) }
    }

    deinit {
        if let token { end(token) }
    }
}
