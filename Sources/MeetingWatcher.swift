import AppKit
import CoreAudio
import OSLog
import QuartzCore
import SwiftUI

@MainActor
protocol MicActivityMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    var isListening: Bool { get }
    var requiresPolling: Bool { get }
    var isAnyInputRunning: Bool { get }
    func start()
    func stop()
}

@MainActor
protocol MicUsageQuerying {
    func inputBundleIDs(matching prefixes: [String]) -> [String]
}

@MainActor
protocol MeetingRecordingControl: AnyObject {
    var isRecording: Bool { get }
    var isStarting: Bool { get }
    var isSaving: Bool { get }
    var isEditing: Bool { get }
    func start()
    func stop()
}

/// 회의 앱이 마이크를 쓰기 시작하면 녹음을 제안하고, 마이크를 놓으면 정지를 제안한다.
@MainActor
final class MeetingWatcher: ObservableObject {
    struct MeetingApp: Identifiable {
        let id: String
        let name: String
        let prefixes: [String]  // 번들 ID 앞부분(도우미 프로세스까지 잡도록)
        let enabledByDefault: Bool

        var key: String { "detect.\(id)" }
    }

    static let apps = [
        MeetingApp(id: "phone", name: "전화", prefixes: ["com.apple.mobilephone"], enabledByDefault: false),
        MeetingApp(id: "teams", name: "Microsoft Teams", prefixes: ["com.microsoft.teams"], enabledByDefault: true),
        MeetingApp(id: "works", name: "NAVER WORKS", prefixes: ["com.naver.naverworks", "com.worksmobile"], enabledByDefault: true),
        MeetingApp(id: "zoom", name: "Zoom", prefixes: ["us.zoom"], enabledByDefault: true),
        MeetingApp(
            id: "browser", name: "웹 브라우저",
            prefixes: ["com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "com.microsoft.edgemac",
                       "com.naver.Whale", "org.mozilla.firefox", "company.thebrowser"],
            enabledByDefault: false),
    ]

    static let enabledKey = "detectMeetings"
    static let autoStopKey = "autoStopAfterMeeting"
    static let phoneAutoRecordKey = "autoRecordPhoneCalls"
    static let autoStopSeconds = 120
    static let promptSeconds = 60

    static var defaults: [String: Any] {
        var values: [String: Any] = [enabledKey: true, autoStopKey: true, phoneAutoRecordKey: true]
        for app in apps { values[app.key] = app.enabledByDefault }
        return values
    }

    static var enabledAppNames: [String] {
        apps.filter { UserDefaults.standard.bool(forKey: $0.key) }.map(\.name)
    }

    @Published private(set) var activeApp: String?

    /// 점검용(--snapshot): 감지 없이 '회의 중' 화면만 보여 준다.
    func previewActiveApp(_ name: String?) {
        guard LaunchMode.isCheck else { return }
        activeApp = name
    }

    private enum PromptKind { case start, end }

    private weak var recorder: (any MeetingRecordingControl)?
    private var phoneAutoStarted = false
    private var phoneOwnsRecording = false
    private var phoneEndMisses = 0
    private var timer: Timer?
    private var hits = 0
    private var misses = 0
    private let panel = PromptPanel()
    private let defaults: UserDefaults
    private let micUsage: any MicUsageQuerying
    private let micActivity: any MicActivityMonitoring
    private var defaultsObserver: NSObjectProtocol?
    private var promptKind: PromptKind?
    private var promptTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         micActivity: (any MicActivityMonitoring)? = nil,
         micUsage: (any MicUsageQuerying)? = nil) {
        self.defaults = defaults
        self.micActivity = micActivity ?? MicActivity()
        self.micUsage = micUsage ?? MicUsage()
        self.micActivity.onChange = { [weak self] in self?.micActivityChanged() }
    }

    deinit {
        timer?.invalidate()
        promptTask?.cancel()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func attach(_ recorder: any MeetingRecordingControl) {
        self.recorder = recorder
        // 설정에서 감지를 켜고 끌 때 리스너와 타이머도 함께 켜고 끈다.
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDetection() }
        }
        updateDetection()
    }

    private var candidates: [(name: String, prefixes: [String])] {
        var candidates = Self.apps.filter { defaults.bool(forKey: Self.enabledKey) && defaults.bool(forKey: $0.key) }
            .map { ($0.name, $0.prefixes) }
        if defaults.bool(forKey: Self.phoneAutoRecordKey) || phoneOwnsRecording {
            candidates.removeAll { $0.0 == "전화" }
            candidates.insert(("전화", ["com.apple.mobilephone"]), at: 0)
        }
        // 점검용 추가 번들 ID도 감지 대상으로 취급한다.
        let extra = (defaults.stringArray(forKey: "detectExtraPrefixes") ?? []).filter { !$0.isEmpty }
        if defaults.bool(forKey: Self.enabledKey), !extra.isEmpty { candidates.append(("테스트 앱", extra)) }
        return candidates
    }

    private var isEnabled: Bool { !candidates.isEmpty }
    var isPolling: Bool { timer != nil }

    // MARK: - 켜고 끄기

    /// 대기 중에는 아무 타이머도 돌리지 않는다. 마이크 장치가 켜지면 Core Audio가 알려 주고(MicActivity),
    /// 그때부터 어떤 앱이 쓰는지 2초마다 확인한다. 알림을 걸 수 없으면 예전처럼 늘 2초마다 확인한다.
    func updateDetection() {
        if isEnabled {
            if !micActivity.isListening { micActivity.start() }
            updatePolling()
        } else {
            stopDetection()
        }
    }

    private var needsPolling: Bool {
        guard isEnabled else { return false }
        guard !micActivity.requiresPolling else { return true }
        // 제안 창의 응답 대기는 자체 Task가 관리한다. 창 때문에 오디오 조회를 계속하지 않는다.
        return activeApp != nil || hits > 0 || micActivity.isAnyInputRunning
    }

    private func updatePolling() {
        let shouldPoll = needsPolling
        if shouldPoll, timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            // 정확히 2초일 필요가 없으므로 시스템이 다른 깨어남과 묶어 처리하게 둔다.
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            audioLog.info("회의 감지: 마이크가 켜져 2초 확인 시작")
        } else if !shouldPoll, let timer {
            timer.invalidate()
            self.timer = nil
            audioLog.info("회의 감지: 마이크가 꺼져 확인 중지, 대기")
        }
    }

    /// 마이크 장치가 켜지거나 꺼졌다. 폴링을 새로 시작하면 바로 한 번 확인한다.
    private func micActivityChanged() {
        guard isEnabled else { return }
        let wasPolling = timer != nil
        updatePolling()
        if !wasPolling, timer != nil { poll() }
    }

    private func stopDetection() {
        timer?.invalidate()
        timer = nil
        micActivity.stop()
        if activeApp != nil { activeApp = nil }
        if promptKind != nil { closePrompt() }
        hits = 0
        misses = 0
        phoneAutoStarted = false
        phoneOwnsRecording = false
        phoneEndMisses = 0
    }

    /// 녹음이 멈추면 정지 제안 창을 닫는다.
    func recordingStopped() {
        if promptKind == .end { closePrompt() }
    }

    // MARK: - 감지

    func poll() {
        guard isEnabled else { return stopDetection() }
        defer { updatePolling() }
        if promptKind == .start, recorder?.isRecording == true { closePrompt() }

        // 시작은 2번 연속(약 4초), 끝은 5번 연속(약 10초) 확인해 잠깐의 끊김을 무시한다.
        let detected = currentMeetingApp()
        if phoneOwnsRecording, detected != "전화" {
            phoneEndMisses += 1
            // 장치 전환의 짧은 입력 끊김은 한 번 넘기고, 약 2~4초 내 자동 저장한다.
            if phoneEndMisses >= 2 {
                phoneOwnsRecording = false
                phoneAutoStarted = false
                phoneEndMisses = 0
                activeApp = nil
                hits = 0
                misses = 0
                closePrompt()
                if recorder?.isRecording == true || recorder?.isStarting == true { recorder?.stop() }
            }
            return
        }
        phoneEndMisses = 0
        if let name = detected {
            misses = 0
            hits = min(hits + 1, 2)
            if name == "전화", defaults.bool(forKey: Self.phoneAutoRecordKey) || phoneOwnsRecording {
                if activeApp != "전화" { phoneAutoStarted = false }
                activeApp = "전화"
                closePrompt()
                if recorder?.isRecording == true || recorder?.isStarting == true { phoneAutoStarted = true }
                if !phoneAutoStarted, let recorder,
                   !recorder.isRecording, !recorder.isStarting, !recorder.isSaving, !recorder.isEditing {
                    // 이 통화에서 사용자가 수동 정지했다면 다시 자동 시작하지 않는다.
                    phoneAutoStarted = true
                    phoneOwnsRecording = true
                    recorder.start()
                }
                return
            }
            if activeApp == nil, hits >= 2 {
                activeApp = name
                meetingStarted(name)
            }
        } else {
            hits = 0
            guard let name = activeApp else { return }
            misses += 1
            if misses >= 5 {
                activeApp = nil
                phoneAutoStarted = false
                meetingEnded(name)
            }
        }
    }

    private func currentMeetingApp() -> String? {
        let candidates = candidates
        let users = micUsage.inputBundleIDs(matching: candidates.flatMap { $0.1 })
        return candidates.first { _, prefixes in
            users.contains { id in prefixes.contains { id.hasPrefix($0) } }
        }?.0
    }

    // MARK: - 제안 창

    private func meetingStarted(_ name: String) {
        audioLog.notice("회의 감지: \(name, privacy: .public) 시작")
        // 정지 제안 중에 회의가 다시 이어지면 제안을 거둔다.
        if promptKind == .end {
            closePrompt()
            return
        }
        guard let recorder, !recorder.isRecording, !recorder.isStarting, !recorder.isSaving, !recorder.isEditing else { return }
        showPrompt(.start, MeetingPromptView(
            kind: .start,
            title: "\(name) 회의가 시작된 것 같습니다",
            message: "녹음할까요? 녹음하기 전에 참석자 동의를 받으세요.",
            primary: "녹음 시작", secondary: "이번엔 안 함", deadline: nil,
            onPrimary: { [weak self] in
                self?.closePrompt()
                self?.recorder?.start()
            },
            onSecondary: { [weak self] in self?.closePrompt() }))
        // 응답이 없으면 창만 닫고 녹음하지 않는다.
        promptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.promptSeconds))
            if !Task.isCancelled { self?.closePrompt() }
        }
    }

    private func meetingEnded(_ name: String) {
        audioLog.notice("회의 감지: \(name, privacy: .public) 끝")
        if promptKind == .start { closePrompt() }
        guard let recorder, recorder.isRecording else { return }

        let autoStop = defaults.bool(forKey: Self.autoStopKey)
        let deadline = autoStop ? Date().addingTimeInterval(Double(Self.autoStopSeconds)) : nil
        showPrompt(.end, MeetingPromptView(
            kind: .end,
            title: "\(name) 회의가 끝난 것 같습니다",
            message: "녹음을 정지할까요?",
            primary: "녹음 정지", secondary: "계속 녹음", deadline: deadline,
            onPrimary: { [weak self] in
                self?.closePrompt()
                self?.recorder?.stop()
            },
            onSecondary: { [weak self] in self?.closePrompt() }))
        guard autoStop else { return }
        promptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoStopSeconds))
            guard !Task.isCancelled, let self, self.promptKind == .end else { return }
            audioLog.notice("회의 감지: 응답이 없어 녹음을 자동 정지")
            self.closePrompt()
            self.recorder?.stop()
        }
    }

    private func showPrompt(_ kind: PromptKind, _ view: MeetingPromptView) {
        closePrompt()
        promptKind = kind
        panel.show(view)
    }

    private func closePrompt() {
        promptTask?.cancel()
        promptTask = nil
        promptKind = nil
        panel.close()
    }
}

/// 마이크 장치가 켜지고 꺼지는 것을 Core Audio 알림으로 받는다. 어떤 프로세스가 켰는지는 알려 주지 않고
/// (프로세스별 입력 상태는 알림이 오지 않는 것을 확인했다), "누군가 켰다"는 사실만 온다.
/// 입력 스트림이 있는 모든 장치(내장·USB·블루투스·가상 장치)에 걸고, 장치가 바뀌면 다시 건다.
@MainActor
final class MicActivity: MicActivityMonitoring {
    var onChange: (() -> Void)?
    private(set) var isListening = false

    private let queue = DispatchQueue(label: "MeetingRecorder.mic-activity")
    private var deviceBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var inputDevices: Set<AudioObjectID> = []
    private var runningDevices: Set<AudioObjectID> = []

    /// 알림에서만 갱신한다. 2초마다 장치 목록·입력 스트림을 다시 조회하지 않는다.
    var isAnyInputRunning: Bool { !runningDevices.isEmpty }

    /// 일부 장치만 알림 등록에 실패해도 폴링으로 보완해 회의 시작을 놓치지 않는다.
    var requiresPolling: Bool { !isListening || deviceBlocks.count != inputDevices.count }

    func start() {
        guard !isListening else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.syncDevices()
                self.onChange?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        guard status == noErr else {
            audioLog.error("마이크 장치 알림을 걸지 못해 2초 폴링으로 대신합니다: \(status, privacy: .public)")
            return
        }
        devicesBlock = block
        isListening = true
        syncDevices()
        audioLog.info("마이크 장치 알림 등록: \(self.deviceBlocks.count, privacy: .public)개 장치")
    }

    func stop() {
        guard isListening else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        if let devicesBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, devicesBlock)
        }
        devicesBlock = nil
        for (device, block) in deviceBlocks { remove(block, from: device) }
        deviceBlocks = [:]
        inputDevices = []
        runningDevices = []
        isListening = false
    }

    private func syncDevices() {
        let devices = Set(Self.inputDevices())
        inputDevices = devices
        for (device, block) in deviceBlocks where !devices.contains(device) {
            remove(block, from: device)
            deviceBlocks[device] = nil
        }
        for device in devices where deviceBlocks[device] == nil {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.isListening, self.inputDevices.contains(device) else { return }
                    if Self.isRunningSomewhere(device) {
                        self.runningDevices.insert(device)
                    } else {
                        self.runningDevices.remove(device)
                    }
                    self.onChange?()
                }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                deviceBlocks[device] = block
            }
        }
        // 리스너를 먼저 등록해 초기 조회 직후의 상태 변경도 놓치지 않는다.
        runningDevices = Set(devices.filter(Self.isRunningSomewhere))
    }

    private func remove(_ block: @escaping AudioObjectPropertyListenerBlock, from device: AudioObjectID) {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        // 이미 빠진 장치면 실패하지만 상관없다.
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
    }

    private static func inputDevices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Core Audio에 지금 마이크 입력을 쓰는 프로세스를 묻는다. 소리는 듣지 않으며 권한도 필요 없다.
/// 매번 모든 프로세스(30여 개)에 묻지 않도록 번들 ID는 프로세스마다 한 번만 묻고 기억해 두고,
/// 마이크 사용 여부는 회의 앱 후보에게만 묻는다.
@MainActor
final class MicUsage: MicUsageQuerying {
    private var bundleIDs: [AudioObjectID: String] = [:]

    func inputBundleIDs(matching prefixes: [String]) -> [String] {
        guard !prefixes.isEmpty else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        let alive = Set(processes)
        bundleIDs = bundleIDs.filter { alive.contains($0.key) }
        let detectPhone = prefixes.contains { $0.hasPrefix("com.apple.mobilephone") }
        let phoneRunning = detectPhone && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mobilephone").isEmpty
        let faceTimeRunning = detectPhone && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").isEmpty
        return processes.compactMap { process in
            let bundleID = bundleIDs[process] ?? Self.bundleID(of: process)
            bundleIDs[process] = bundleID.isEmpty ? nil : bundleID
            let id = Self.detectionID(bundleID, phoneRunning: phoneRunning, faceTimeRunning: faceTimeRunning)
            guard prefixes.contains(where: { id.hasPrefix($0) }), Self.isRunningInput(process) else { return nil }
            return id
        }
    }

    /// OS에 따라 통화 마이크가 Phone 대신 공유 통화 서비스에 속한다.
    /// FaceTime도 열려 있어 주체를 구분할 수 없으면 공유 서비스로 자동 녹음하지 않는다.
    static func detectionID(_ id: String, phoneRunning: Bool, faceTimeRunning: Bool) -> String {
        let shared = ["com.apple.avconferenced", "com.apple.videoconference", "com.apple.telephonyutilities.callservicesd", "com.apple.callservicesd"]
        if phoneRunning, !faceTimeRunning, shared.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
            return "com.apple.mobilephone.audio"
        }
        return id
    }

    private static func bundleID(of process: AudioObjectID) -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(kAudioProcessPropertyBundleID)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return "" }
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioProcessPropertyIsRunningInput)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// 화면 오른쪽 위에 뜨는 작은 제안 창. 다른 앱의 포커스를 빼앗지 않는다.
/// 오른쪽에서 살짝 미끄러져 들어오고, 닫힐 때는 흐려지며 사라진다.
@MainActor
final class PromptPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: NSPanel?

    func show(_ view: MeetingPromptView) {
        close()
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let final = NSRect(
            origin: NSPoint(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 12), size: size)
        panel.setFrame(final.offsetBy(dx: 28, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.15, 0.35, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame.offsetBy(dx: 20, dy: 0), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

struct MeetingPromptView: View {
    enum Kind { case start, end }

    let kind: Kind
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let deadline: Date?
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    private let shownAt = Date()
    @State private var appeared = false

    private var gradient: LinearGradient { kind == .start ? Theme.brand : Theme.sunset }
    private var tint: Color { kind == .start ? Theme.blue : Theme.orange }
    private var symbol: String { kind == .start ? "waveform.and.mic" : "hand.wave.fill" }
    private var eyebrow: String { kind == .start ? "회의 감지" : "회의 종료 감지" }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(gradient)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            .frame(width: 44, height: 44)
            .shadow(color: tint.opacity(appeared ? 0.4 : 0.1), radius: appeared ? 9 : 3, y: 4)
            .animation(.easeOut(duration: 0.6), value: appeared)

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline {
                    CountdownBar(deadline: deadline, total: max(1, deadline.timeIntervalSince(shownAt)), tint: tint)
                        .padding(.top, 6)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(secondary, action: onSecondary)
                        .buttonStyle(PillButtonStyle(prominent: false, tint: tint))
                    Button(primary, action: onPrimary)
                        .buttonStyle(PillButtonStyle(prominent: true, tint: tint, gradient: gradient))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .scaleEffect(appeared ? 1 : 0.94, anchor: .topTrailing)
        .animation(.spring(duration: 0.6, bounce: 0.3), value: appeared)
        .onAppear { appeared = true }
    }
}

/// 자동 정지까지 남은 시간을 가는 막대와 숫자로 보여 준다.
private struct CountdownBar: View {
    let deadline: Date
    let total: TimeInterval
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, deadline.timeIntervalSince(context.date))
            let urgent = left <= 10
            let color = urgent ? Theme.red : tint
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("응답이 없으면 자동으로 정지합니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                        .contentTransition(.numericText(countsDown: true))
                        .scaleEffect(urgent ? 1.1 : 1, anchor: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(left / total))
                            .shadow(color: color.opacity(urgent ? 0.6 : 0), radius: 3)
                    }
                }
                .frame(height: 3)
            }
            .animation(.linear(duration: 1), value: left)
            .animation(.spring(duration: 0.4, bounce: 0.4), value: urgent)
        }
    }
}
