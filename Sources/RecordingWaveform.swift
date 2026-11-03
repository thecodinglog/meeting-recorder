import Accelerate
import AVFoundation

enum RecordingWaveform {
    /// 파일 전체를 메모리에 올리지 않고 일정한 수의 최대 진폭으로 축약한다.
    static func load(_ url: URL, duration: Double, bins: Int = 900) async throws -> [Float] {
        let worker = Task.detached(priority: .utility) {
            try await read(url, duration: duration, bins: bins)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func read(_ url: URL, duration: Double, bins: Int) async throws -> [Float] {
        guard duration.isFinite, duration > 0, bins > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingError.invalid("파형을 읽지 못했습니다.") }
        defer { reader.cancelReading() }
        var peaks = [Float](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let asbd = sample.formatDescription?.audioStreamBasicDescription,
                  asbd.mSampleRate > 0, asbd.mBitsPerChannel == 32 else { continue }
            let seconds = max(0, sample.presentationTimeStamp.seconds)
            let framesPerBin = max(1, duration * asbd.mSampleRate / Double(bins))
            let baseFrame = seconds.isFinite ? seconds * asbd.mSampleRate : 0
            try sample.withAudioBufferList { buffers, _ in
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let frames = min(sample.numSamples, Int(buffer.mDataByteSize) / (4 * channels))
                    let samples = data.assumingMemoryBound(to: Float.self)
                    var frame = 0
                    while frame < frames {
                        let bin = min(bins - 1, max(0, Int((baseFrame + Double(frame)) / framesPerBin)))
                        let next = min(frames, max(frame + 1, Int(ceil(Double(bin + 1) * framesPerBin - baseFrame))))
                        var peak: Float = 0
                        vDSP_maxmgv(samples.advanced(by: frame * channels), 1, &peak, vDSP_Length((next - frame) * channels))
                        peaks[bin] = max(peaks[bin], min(peak, 1))
                        frame = next
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? RecordingError.invalid("파형을 끝까지 읽지 못했습니다.") }
        return peaks
    }
}

enum TrimTimelineMath {
    static func time(at x: Double, width: Double, duration: Double) -> Double {
        guard width > 28, duration.isFinite, duration > 0, x.isFinite else { return 0 }
        return min(max((x - 14) / (width - 28), 0), 1) * duration
    }
    static func start(_ value: Double, end: Double, duration: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), max(0, min(end, duration) - min(0.1, duration)))
    }
    static func end(_ value: Double, start: Double, duration: Double) -> Double {
        max(min(value.isFinite ? value : duration, duration), min(duration, max(0, start) + min(0.1, duration)))
    }
}
