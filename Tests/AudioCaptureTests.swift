import AVFoundation
import Testing
@testable import MeetingRecorder

private func tone(rate: Double = 48_000, channels: AVAudioChannelCount = 1,
                  seconds: Double = 0.1, time: Double = 100) throws -> CMSampleBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = AVAudioFrameCount(rate * seconds)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    pcm.frameLength = frames
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frames) {
            pcm.floatChannelData![channel][frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / Float(rate))
        }
    }
    return try AudioSamples.copy(pcm.audioBufferList, format: format, frames: Int(frames),
                                 time: CMTime(seconds: time, preferredTimescale: 1_000_000))
}

struct AudioCaptureTests {
    @Test func halBuffersAreCopiedWithTimestampAndBothChannels() throws {
        let sample = try tone(channels: 2, time: 42.25)
        #expect(CMSampleBufferDataIsReady(sample))
        #expect(sample.numSamples == 4_800)
        #expect(sample.presentationTimeStamp.seconds == 42.25)
        #expect(sample.formatDescription?.audioStreamBasicDescription?.mChannelsPerFrame == 2)
        // tone()의 원본 PCM은 이미 해제됐다. 복사된 양쪽 채널이 살아 있어야 한다.
        try sample.withAudioBufferList { buffers, _ in
            #expect(buffers.count == 2)
            for buffer in buffers {
                let values = UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: 4_800)
                #expect(values.map { abs($0) }.max()! > 0.29)
            }
        }
    }

    @Test func bluetoothFormatChangesKeepStableStorageFormat() throws {
        let normalizer = AudioNormalizer(channels: 1)
        for (index, rate) in [48_000.0, 16_000, 24_000, 48_000].enumerated() {
            let time = 100 + Double(index) * 0.1
            let converted = try normalizer.convert(tone(rate: rate, time: time))
            let sample = try #require(converted)
            let format = try #require(sample.formatDescription?.audioStreamBasicDescription)
            #expect(format.mSampleRate == 48_000)
            #expect(format.mChannelsPerFrame == 1)
            #expect(sample.presentationTimeStamp.seconds == time)
            #expect(abs(Double(sample.numSamples) / 48_000 - 0.1) < 0.005)
        }
    }

    @Test func separateTracksAndMixPreserveBothInputsAndStartOffset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = AudioSink(folder: folder)
        // 마이크가 늦게 시작하고 도중 입력 주파수가 바뀌는 통화를 재현한다.
        for index in 0..<15 {
            let system = try tone(channels: 2, time: 100 + Double(index) * 0.1)
            let mic = try tone(rate: index < 8 ? 16_000 : 24_000, time: 100.25 + Double(index) * 0.1)
            sink.queue.sync {
                sink.append(system, microphone: false)
                sink.append(mic, microphone: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let levels = sink.takeLevels()
        #expect(levels.system > 0.5)
        #expect(levels.microphone > 0.5)
        let result = await sink.finish()
        #expect(result.errors.isEmpty)
        #expect(result.tracks.count == 2)
        let system = try #require(result.tracks.first { $0.url.lastPathComponent == "시스템.m4a" })
        let mic = try #require(result.tracks.first { $0.url.lastPathComponent == "마이크.m4a" })
        #expect(abs(CMTimeSubtract(mic.startTime, system.startTime).seconds - 0.25) < 0.001)
        for track in result.tracks {
            let file = try AVAudioFile(forReading: track.url)
            #expect(file.length > 65_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
            try file.read(into: buffer)
            let values = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            #expect(values.map { abs($0) }.max()! > 0.1)
        }
        let output = folder.appendingPathComponent("전체.m4a")
        try await Mixer.mix(result.tracks, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 1.6 && duration < 1.9)
    }

    @Test func systemOnlyRecordingDoesNotCreateMicrophoneFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = AudioSink(folder: folder)
        let sample = try tone(channels: 2, seconds: 0.5)
        sink.queue.sync { sink.append(sample, microphone: false) }
        let result = await sink.finish()
        #expect(result.errors.isEmpty)
        #expect(result.tracks.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("마이크.m4a").path))
    }
}
