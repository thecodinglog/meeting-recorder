import AppKit
import Darwin

/// 실제 캡처를 반복하는 수동 통합 점검: --lifecycle-check <결과 폴더>
/// 시스템 소리와 마이크를 3초씩 12번 녹음한다. 회의 감지는 유지하고 전사는 생략한다.
/// 녹음·보고서는 지정한 폴더에만 저장하며 사용자 설정은 바꾸지 않는다.
enum LifecycleCheck {
    static var outputFolder: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--lifecycle-check"), args.count > i + 1 else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    struct Sample: Codable {
        let cycle: Int
        let date: Date
        let footprintMiB: Double
        let residentMiB: Double
        let cpuSeconds: Double
        let captureIdle: Bool
        let meetingPolling: Bool
        let retainedStreams: Int
        let retainedSinks: Int
        let recordingPath: String?
    }

    struct Report: Codable {
        var pid = ProcessInfo.processInfo.processIdentifier
        var samples: [Sample] = []
        var finished = false
        var failure: String?
        var finalIdleCPUPercent: Double?
    }

    enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? {
            switch self { case .check(let text): text }
        }
    }

    @MainActor
    static func runIfRequested(_ recorder: Recorder) {
        guard let folder = outputFolder else { return }
        Task {
            var report = Report()
            var probes: [CaptureResourceProbe] = []
            func save() throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await Task.sleep(for: .seconds(8))
                report.samples.append(try sample(recorder, cycle: 0, probes: probes))
                try save()
                for cycle in 1...12 {
                    let previous = recorder.lastRecording
                    recorder.start()
                    recorder.start() // 연속 클릭도 같은 캡처 하나만 시작해야 한다.
                    try await waitUntil("녹음 시작", seconds: 20) { !recorder.isStarting }
                    guard recorder.isRecording else {
                        throw Failure.check(recorder.message ?? "녹음을 시작하지 못했습니다")
                    }
                    probes.append(recorder.captureResourceProbe())
                    try await Task.sleep(for: .seconds(3))
                    recorder.stop()
                    recorder.stop() // 중복 정지도 저장을 한 번만 실행해야 한다.
                    try await waitUntil("녹음 저장", seconds: 30) { recorder.isCaptureIdle }
                    guard recorder.lastRecording != previous, recorder.message == nil else {
                        throw Failure.check(recorder.message ?? "새 녹음 파일이 저장되지 않았습니다")
                    }
                    try await Task.sleep(for: .seconds(5))
                    let state = try sample(recorder, cycle: cycle, probes: probes)
                    report.samples.append(state)
                    try save()
                    guard state.captureIdle, state.retainedStreams == 0, state.retainedSinks == 0 else {
                        throw Failure.check("\(cycle)회 후 캡처 자원이 해제되지 않았습니다")
                    }
                }
                let before = try sample(recorder, cycle: 12, probes: probes)
                let began = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(30))
                let after = try sample(recorder, cycle: 12, probes: probes)
                report.samples.append(after)
                report.finalIdleCPUPercent = 100 * (after.cpuSeconds - before.cpuSeconds) /
                    (ProcessInfo.processInfo.systemUptime - began)
            } catch {
                report.failure = error.localizedDescription
            }
            report.finished = true
            try? save()
            recorder.quit()
        }
    }

    @MainActor
    private static func waitUntil(_ name: String, seconds: Double, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.check("\(name) 시간 초과") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private static func sample(_ recorder: Recorder, cycle: Int, probes: [CaptureResourceProbe]) throws -> Sample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.check("메모리 측정 실패: \(result)") }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.check("CPU 측정 실패") }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Sample(cycle: cycle, date: Date(), footprintMiB: Double(info.phys_footprint) / 1_048_576,
                      residentMiB: Double(info.resident_size) / 1_048_576, cpuSeconds: cpu,
                      captureIdle: recorder.isCaptureIdle, meetingPolling: recorder.watcher.isPolling,
                      retainedStreams: probes.filter { $0.stream != nil }.count,
                      retainedSinks: probes.filter { $0.sink != nil }.count,
                      recordingPath: recorder.lastRecording?.path)
    }
}

/// 관찰 자체가 캡처 자원을 살려 두지 않도록 약한 참조만 보관한다.
final class CaptureResourceProbe {
    weak var stream: AudioCapture?
    weak var sink: AudioSink?

    init(stream: AudioCapture?, sink: AudioSink?) {
        self.stream = stream
        self.sink = sink
    }
}
