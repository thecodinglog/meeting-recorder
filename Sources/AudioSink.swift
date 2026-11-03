import Accelerate
import AVFoundation
import OSLog

/// 시스템 소리와 독립 마이크 입력을 각각 m4a 파일로 쓴다.
final class AudioSink: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "MeetingRecorder.audio")
    let folder: URL
    var onStop: ((Error) -> Void)?

    private let system: TrackWriter
    private let microphone: TrackWriter
    private let systemNormalizer = AudioNormalizer(channels: 2)
    private let microphoneNormalizer = AudioNormalizer(channels: 1)
    private var inputFailed = false

    // 마지막으로 읽어 간 뒤의 최대 소리 크기(0~1)
    private let levelLock = NSLock()
    private var systemPeak: Float = 0
    private var microphonePeak: Float = 0

    init(folder: URL) {
        self.folder = folder
        system = TrackWriter(url: folder.appendingPathComponent("시스템.m4a"))
        microphone = TrackWriter(url: folder.appendingPathComponent("마이크.m4a"))
    }

    /// 두 캡처 모두 queue에서 호출한다. 파일 쓰기와 변환기의 동시 접근을 막는다.
    func append(_ sampleBuffer: CMSampleBuffer, microphone isMicrophone: Bool) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard !inputFailed else { return }
        do {
            let normalizer = isMicrophone ? microphoneNormalizer : systemNormalizer
            guard let sample = try normalizer.convert(sampleBuffer) else { return }
            let writer = isMicrophone ? microphone : system
            writer.append(sample)
            let level = Self.level(of: sample)
            levelLock.withLock {
                if isMicrophone { microphonePeak = max(microphonePeak, level) }
                else { systemPeak = max(systemPeak, level) }
            }
        } catch {
            inputFailed = true
            onStop?(error)
        }
    }

    /// 화면 갱신 때마다 호출한다. 읽은 뒤 0으로 되돌린다.
    func takeLevels() -> (system: Float, microphone: Float) {
        levelLock.withLock {
            defer { systemPeak = 0; microphonePeak = 0 }
            return (systemPeak, microphonePeak)
        }
    }

    /// 버퍼의 최대 진폭을 -50dB~0dB 범위의 0~1 값으로 바꾼다.
    private static func level(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return 0 }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                if isFloat {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    var m: Float = 0
                    vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(count))
                    peak = max(peak, m)
                } else if asbd.mBitsPerChannel == 16 {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
                    let m = samples.reduce(0) { max($0, abs(Int32($1))) }
                    peak = max(peak, Float(m) / 32768)
                }
            }
        }
        let db = 20 * log10(max(peak, 0.000_01))
        return min(max((db + 50) / 50, 0), 1)
    }

    /// 캡처가 멈춘 뒤 호출한다. 내용이 있는 트랙과 실패한 트랙의 오류를 돌려준다.
    func finish() async -> (tracks: [Track], errors: [String]) {
        queue.sync {}  // 대기 중인 버퍼를 먼저 비운다.
        var tracks: [Track] = []
        var errors: [String] = []
        for (name, writer) in [("시스템", system), ("마이크", microphone)] {
            if let track = await writer.finish() { tracks.append(track) }
            if let error = writer.error { errors.append("\(name) 저장 실패: \(error)") }
        }
        return (tracks, errors)
    }
}

let audioLog = Logger(subsystem: "local.cothe.MeetingRecorder", category: "audio")

struct Track {
    let url: URL
    let startTime: CMTime
}

/// 첫 버퍼의 형식에 맞춰 AAC 인코더를 만든다.
final class TrackWriter {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private(set) var error: String?

    init(url: URL) {
        self.url = url
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        if writer == nil, error == nil { setUp(with: sampleBuffer) }
        guard let writer, let input else { return }
        guard writer.status == .writing else { return noteFailure(writer) }
        if input.isReadyForMoreMediaData, !input.append(sampleBuffer) { noteFailure(writer) }
    }

    func finish() async -> Track? {
        guard let writer, let input, let startTime else { return nil }
        guard writer.status == .writing else {
            noteFailure(writer)
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            noteFailure(writer)
            return nil
        }
        return Track(url: url, startTime: startTime)
    }

    private func noteFailure(_ writer: AVAssetWriter?, _ fallback: String = "알 수 없는 오류") {
        guard error == nil else { return }
        let message = writer?.error.map { "\($0.localizedDescription) (\(($0 as NSError).code))" } ?? fallback
        error = message
        audioLog.error("\(self.url.lastPathComponent, privacy: .public) 저장 실패: \(message, privacy: .public)")
    }

    private func setUp(with sampleBuffer: CMSampleBuffer) {
        guard let format = sampleBuffer.formatDescription,
              let asbd = format.audioStreamBasicDescription else {
            return noteFailure(nil, "오디오 형식을 읽지 못했습니다")
        }
        audioLog.info("""
            \(self.url.lastPathComponent, privacy: .public) 입력 형식: \(asbd.mSampleRate, privacy: .public)Hz \
            \(asbd.mChannelsPerFrame, privacy: .public)ch \(asbd.mBitsPerChannel, privacy: .public)bit \
            flags=\(asbd.mFormatFlags, privacy: .public)
            """)
        // 비트레이트는 지정하지 않는다. 16·24kHz 블루투스 마이크에서 높은 값을 주면 인코더가 거부한다.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: min(max(Int(asbd.mChannelsPerFrame), 1), 2),
        ]
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canApply(outputSettings: settings, forMediaType: .audio), writer.canAdd(input) else {
                return noteFailure(nil, "이 오디오 형식으로 m4a 파일을 저장할 수 없습니다")
            }
            writer.add(input)
            guard writer.startWriting() else { return noteFailure(writer) }
            let start = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            self.writer = writer
            self.input = input
            startTime = start
        } catch {
            noteFailure(nil, error.localizedDescription)
        }
    }
}
