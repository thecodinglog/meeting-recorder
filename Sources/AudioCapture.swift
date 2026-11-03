import AVFoundation
import CoreAudio
import OSLog

/// 화면 캡처와 독립적으로 시스템 출력과 마이크를 받는다.
/// Phone/FaceTime의 배경 통화 프로세스도 전역 오디오 탭에 포함된다.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let control = DispatchQueue(label: "MeetingRecorder.capture")
    private let sink: AudioSink
    private var tap: SystemAudioTap?
    private var microphone: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(sink: AudioSink) { self.sink = sink }

    func start(withMicrophone: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    // Bluetooth는 마이크를 열 때 통화 모드로 전환한다. 전환을 먼저 끝내야
                    // 출력 탭이 이전 재생 모드에 묶여 마이크가 무음이 되는 일을 피한다.
                    if withMicrophone { try self.startMicrophone() }
                    let tap = SystemAudioTap(queue: self.sink.queue, sink: self.sink)
                    self.tap = tap
                    try tap.start()
                    self.running = true
                    continuation.resume()
                } catch {
                    self.stopCapture()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            control.async {
                self.stopCapture()
                continuation.resume()
            }
        }
    }

    private func startMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureFailure.message("녹음할 마이크를 찾지 못했습니다.")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input) else {
            throw CaptureFailure.message("마이크 입력을 열지 못했습니다.")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CaptureFailure.message("마이크 출력을 열지 못했습니다.") }
        session.addOutput(output)
        // 통화 시작 시 Bluetooth 입력 형식이 바뀌어도 저장 형식은 유지한다.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sink.queue)
        microphone = session
        microphoneOutput = output
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.sink.onStop?(error ?? CaptureFailure.message("마이크 녹음이 중단되었습니다."))
        }
        session.startRunning()
        guard session.isRunning else { throw CaptureFailure.message("마이크 녹음을 시작하지 못했습니다.") }

        // 통화 전후 기본 입력이 AirPods/내장 마이크 사이에서 바뀌면 따라간다.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            do { try self.updateMicrophoneInput() }
            catch { self.sink.onStop?(error) }
        }
        var address = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        try checkAudio(AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener), "마이크 변경 감지")
        inputListener = listener
    }

    private func updateMicrophoneInput() throws {
        guard let session = microphone, let device = AVCaptureDevice.default(for: .audio),
              (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID != device.uniqueID else { return }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            previous.forEach { session.addInput($0) }
            throw CaptureFailure.message("변경된 마이크 입력을 열지 못했습니다.")
        }
        session.addInput(input)
        audioLog.info("녹음 마이크 변경: \(device.localizedName, privacy: .public)")
    }

    private func stopCapture() {
        running = false
        if let inputListener {
            var address = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, inputListener)
        }
        inputListener = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        microphone?.stopRunning()
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        // 두 콜백 모두 sink.queue를 쓰므로, drain 후에는 어떤 입력도 파일에 쓰지 않는다.
        tap?.stop()
        sink.queue.sync {}
        microphoneOutput = nil
        microphone = nil
        tap = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let clock = microphone?.synchronizationClock else { return }
        do {
            // AVCapture와 HAL의 서로 다른 시계를 공통 host clock에 맞춘다.
            var timing = CMSampleTimingInfo()
            try checkAudio(CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing), "마이크 시각 읽기")
            timing.presentationTimeStamp = CMSyncConvertTime(timing.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            timing.decodeTimeStamp = .invalid
            var aligned: CMSampleBuffer?
            try checkAudio(CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &aligned), "마이크 시각 맞추기")
            if let aligned { sink.append(aligned, microphone: true) }
        } catch { sink.onStop?(error) }
    }
}

/// HAL 전역 출력 탭. 별도 드라이버 설치나 출력 장치 변경 없이 소리를 복사한다.
private final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private let sink: AudioSink

    init(queue: DispatchQueue, sink: AudioSink) { self.queue = queue; self.sink = sink }
    deinit { stop() }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: try ownAudioProcesses())
        description.name = "회의 녹음기 시스템 소리"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checkAudio(AudioHardwareCreateProcessTap(description, &tapID), "시스템 오디오 탭 만들기")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = audioAddress(kAudioTapPropertyFormat)
        try checkAudio(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "시스템 오디오 형식 읽기")
        guard let format = AVAudioFormat(streamDescription: &asbd), asbd.mBytesPerFrame > 0 else {
            throw CaptureFailure.message("시스템 오디오 형식을 읽지 못했습니다.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "회의 녹음기 오디오 캡처",
            kAudioAggregateDeviceUIDKey: "local.cothe.MeetingRecorder.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try checkAudio(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "오디오 캡처 장치 만들기")
        let sink = self.sink
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, data, time, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
            guard let first = buffers.first, first.mData != nil else { return }
            let frames = Int(first.mDataByteSize / asbd.mBytesPerFrame)
            guard frames > 0 else { return }
            let pts = time.pointee.mFlags.contains(.hostTimeValid)
                ? CMClockMakeHostTimeFromSystemUnits(time.pointee.mHostTime)
                : CMClockGetTime(CMClockGetHostTimeClock())
            do {
                let sample = try AudioSamples.copy(data, format: format, frames: frames, time: pts)
                sink.append(sample, microphone: false)
            } catch { sink.onStop?(error) }
        }, "시스템 오디오 입력 연결")
        try checkAudio(AudioDeviceStart(deviceID, ioProc), "시스템 오디오 녹음 시작")
        audioLog.info("Core Audio 시스템 녹음 시작: \(asbd.mSampleRate, privacy: .public)Hz")
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func ownAudioProcesses() throws -> [AudioObjectID] {
        var pid = ProcessInfo.processInfo.processIdentifier
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = audioAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "녹음 앱 오디오 식별")
        return process == kAudioObjectUnknown ? [] : [process]
    }
}

enum CaptureFailure: LocalizedError {
    case message(String)
    case audio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .audio(let operation, let status): return "\(operation) 실패 (\(status)). 시스템 오디오 녹음과 마이크 권한을 확인하세요."
        }
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw CaptureFailure.audio(operation, status) }
}

private func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                              mElement: kAudioObjectPropertyElementMain)
}
