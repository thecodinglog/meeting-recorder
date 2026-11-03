import AVFoundation

enum AudioSamples {
    /// HAL 버퍼는 콜백 뒤 재사용되므로 CMSampleBuffer가 소유하는 메모리로 복사한다.
    static func copy(_ data: UnsafePointer<AudioBufferList>, format: AVAudioFormat,
                     frames: Int, time: CMTime) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        try checkAudio(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description), "오디오 형식 생성")
        guard let description else { throw CaptureFailure.message("오디오 형식이 없습니다.") }
        var sample: CMSampleBuffer?
        try checkAudio(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: frames, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sample), "오디오 버퍼 생성")
        guard let sample else { throw CaptureFailure.message("오디오 버퍼가 없습니다.") }
        try checkAudio(CMSampleBufferSetDataBufferFromAudioBufferList(sample,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: data), "오디오 버퍼 복사")
        try checkAudio(CMSampleBufferSetDataReady(sample), "오디오 버퍼 준비")
        return sample
    }
}

/// AirPods 통화 모드의 16/24kHz 입력도 저장 중에는 고정 48kHz PCM으로 바꾼다.
/// sink.queue에서만 사용한다.
final class AudioNormalizer {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(channels: AVAudioChannelCount) {
        target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
    }

    func convert(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        guard let description = sample.formatDescription else {
            throw CaptureFailure.message("입력 오디오 형식이 없습니다.")
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        if inputFormat == target {
            converter = nil
            return sample
        }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { throw CaptureFailure.message("오디오 변환기를 만들지 못했습니다.") }
        let capacity = AVAudioFrameCount(ceil(Double(sample.numSamples) * target.sampleRate / inputFormat.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CaptureFailure.message("오디오 변환 버퍼를 만들지 못했습니다.")
        }
        try sample.withAudioBufferList { buffers, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: buffers.unsafePointer) else {
                throw CaptureFailure.message("입력 오디오 버퍼를 읽지 못했습니다.")
            }
            if inputFormat.sampleRate == target.sampleRate {
                // 같은 주파수의 PCM 변환은 동기 API로 모든 프레임을 한 번에 옮긴다.
                try converter.convert(to: output, from: input)
                return
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            if status == .error { throw CaptureFailure.message("오디오 형식을 변환하지 못했습니다.") }
        }
        guard output.frameLength > 0 else { return nil }
        return try AudioSamples.copy(output.audioBufferList, format: target,
                                     frames: Int(output.frameLength), time: sample.presentationTimeStamp)
    }
}
