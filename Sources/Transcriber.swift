import AVFoundation
import OSLog

/// 녹음 폴더의 트랙을 whisper-cli로 따로 전사해 화자별 회의록.txt를 만든다.
/// 마이크 트랙은 "나", 시스템 트랙은 "상대방"으로 적는다.
enum Transcriber {
    private static let paths = TranscriptionPaths()
    static let whisperPath = paths.whisperPath
    static let modelsFolder = paths.modelsFolder
    static let modelPath = modelsFolder.appendingPathComponent("ggml-large-v3-turbo.bin").path
    static let vadModelPath = modelsFolder.appendingPathComponent("ggml-silero-v5.1.2.bin").path

    // 상대방 화자 분리: 앱 전용 가상환경과 로컬 ECAPA 모델을 쓴다.
    static let pythonPath = paths.pythonPath
    static let speakerModelPath = modelsFolder.appendingPathComponent("speaker-ecapa-voxceleb/embedding_model.ckpt").path
    static let diarizeScript = Bundle.main.url(forResource: "diarize", withExtension: "py")?.path ?? ""

    static let transcriptName = "회의록.txt"

    /// whisper-cli 스레드 수. Apple Silicon에서는 성능 코어 수만큼만 준다.
    /// 효율 코어까지 쓰면 더 빨라지지 않고 전력만 더 들며, 녹음·다른 앱과 경쟁한다.
    static let whisperThreads: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let count = sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) == 0 && cores > 0
            ? Int(cores) : ProcessInfo.processInfo.activeProcessorCount
        return min(max(count, 1), 8)
    }()
    private static let offsetsName = ".tracks.json"
    private static let speakers = [("마이크.m4a", "나"), ("시스템.m4a", "상대방")]

    struct Segment {
        var start: Double
        var end: Double
        var speaker: String
        var text: String
    }

    enum Failure: LocalizedError {
        case missing(String)
        case whisper(String)
        case noAudio(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path): "필요한 파일이 없습니다: \(path)"
            case .whisper(let detail): "whisper-cli 실행 실패: \(detail)"
            case .noAudio(let name): "소리를 읽을 수 없는 파일입니다: \(name)"
            }
        }
    }

    /// 파일을 직접 골랐을 때 읽을 수 있는 형식(음성·영상)
    static let fileExtensions = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov", "m4v"]

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: whisperPath)
            && FileManager.default.fileExists(atPath: modelPath)
    }

    static var canSplitSpeakers: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath)
            && [speakerModelPath, diarizeScript].allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    /// 트랙별 시작 시각 차이(초)를 남겨 두어, 나중에 폴더만으로도 다시 전사할 수 있게 한다.
    static func saveOffsets(_ tracks: [Track], in folder: URL) {
        guard let origin = tracks.map(\.startTime).min() else { return }
        var offsets: [String: Double] = [:]
        for track in tracks {
            offsets[track.url.lastPathComponent] = CMTimeSubtract(track.startTime, origin).seconds
        }
        if let data = try? JSONEncoder().encode(offsets) {
            try? data.write(to: folder.appendingPathComponent(offsetsName))
        }
    }

    static func transcribe(folder: URL) async throws -> URL {
        for path in [whisperPath, modelPath] where !FileManager.default.fileExists(atPath: path) {
            throw Failure.missing(path)
        }
        let offsets = (try? Data(contentsOf: folder.appendingPathComponent(offsetsName)))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var segments: [Segment] = []
        for (file, speaker) in speakers {
            let audio = folder.appendingPathComponent(file)
            guard let size = try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
            let wav = work.appendingPathComponent("\(speaker).wav")
            try convertToWav(audio, wav)
            let offset = offsets[file] ?? 0
            var found = try await runWhisper(wav, speaker: speaker, work: work)
            if speaker == "상대방", canSplitSpeakers, found.count > 1 {
                found = await splitSpeakers(found, wav: wav, work: work, name: "상대방")
            }
            for var segment in found {
                segment.start += offset
                segment.end += offset
                segments.append(segment)
            }
        }

        let lines = merge(removeEcho(segments))
        var legend = "나 = 내 마이크, 상대방 = 회의 앱에서 나온 소리"
        if lines.contains(where: { $0.speaker.hasPrefix("상대방") && $0.speaker != "상대방" }) {
            legend += " (상대방 번호는 목소리로 나눠 먼저 말한 순서대로 붙임, 틀릴 수 있음)"
        }
        let output = folder.appendingPathComponent(transcriptName)
        try render(lines, title: folder.lastPathComponent, legend: legend)
            .write(to: output, atomically: true, encoding: .utf8)
        audioLog.info("회의록 작성 완료: 발화 \(lines.count, privacy: .public)개")
        return output
    }

    /// 직접 고른 음성·영상 파일을 전사해 같은 폴더에 "<파일 이름> 회의록.txt"를 만든다.
    /// 목소리가 한 트랙에 섞여 있으므로 나/상대방 대신 목소리로 나눈 "화자1, 화자2…"로 적는다.
    static func transcribe(file: URL) async throws -> URL {
        for path in [whisperPath, modelPath] where !FileManager.default.fileExists(atPath: path) {
            throw Failure.missing(path)
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wav = work.appendingPathComponent("화자.wav")
        try await extractWav(file, wav)
        var segments = try await runWhisper(wav, speaker: "화자", work: work)
        if canSplitSpeakers, segments.count > 1 {
            segments = await splitSpeakers(segments, wav: wav, work: work, name: "화자")
        }

        let lines = merge(segments)
        let legend = lines.contains { $0.speaker != "화자" }
            ? "화자 번호는 목소리로 나눠 먼저 말한 순서대로 붙임(틀릴 수 있음)"
            : "화자 구분 없음"
        let output = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) 회의록.txt")
        try render(lines, title: file.lastPathComponent, legend: legend)
            .write(to: output, atomically: true, encoding: .utf8)
        audioLog.info("파일 회의록 작성 완료: 발화 \(lines.count, privacy: .public)개")
        return output
    }

    /// 영상 파일까지 읽을 수 있도록 AVAssetReader로 소리만 16kHz 모노 WAV로 뽑는다.
    private static func extractWav(_ input: URL, _ output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw Failure.noAudio(input.lastPathComponent) }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(readerOutput)
        guard reader.startReading() else { throw reader.error ?? Failure.noAudio(input.lastPathComponent) }

        var pcm = Data()
        while let buffer = readerOutput.copyNextSampleBuffer() {
            if let bytes = try? buffer.dataBuffer?.dataBytes() { pcm.append(bytes) }
        }
        guard reader.status == .completed, !pcm.isEmpty else {
            throw reader.error ?? Failure.noAudio(input.lastPathComponent)
        }
        try (wavHeader(dataSize: pcm.count) + pcm).write(to: output)
    }

    private static func wavHeader(dataSize: Int) -> Data {
        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)      // fmt 크기
        append16(1)       // PCM
        append16(1)       // 모노
        append32(16_000)  // 샘플레이트
        append32(32_000)  // 초당 바이트
        append16(2)       // 프레임당 바이트
        append16(16)      // 비트
        header.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        return header
    }

    // MARK: - whisper

    /// whisper.cpp가 읽을 수 있도록 16kHz 모노 WAV로 바꾼다.
    private static func convertToWav(_ input: URL, _ output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let destination = try AVAudioFile(
            forWriting: output, settings: target.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let converter = AVAudioConverter(from: source.processingFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 32_768)
        else { throw Failure.missing(input.lastPathComponent) }
        converter.downmix = true

        var finished = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if !finished {
                    try? source.read(into: inBuffer)
                    finished = inBuffer.frameLength == 0
                }
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            if outBuffer.frameLength > 0 { try destination.write(from: outBuffer) }
            if status == .endOfStream || status == .error { break }
        }
    }

    private static func runWhisper(_ wav: URL, speaker: String, work: URL) async throws -> [Segment] {
        let base = work.appendingPathComponent(speaker)
        let logURL = work.appendingPathComponent("\(speaker).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        // -mc 0: 앞 구간 문장을 다음 구간의 힌트로 넘기지 않는다. 같은 문장을 수십 번 반복해 적는 오류가 사라지고
        // 2배 빨라진다(194초 음성 기준 40초 → 19초, 정답 대비 글자 오류 0%).
        var arguments = [
            "-m", modelPath, "-f", wav.path, "-l", "ko", "-mc", "0",
            "-oj", "-of", base.path, "-np",
            "-t", String(whisperThreads),
        ]
        // 무음 구간에서 "감사합니다" 같은 헛말이 나오지 않도록 VAD로 말소리만 넘긴다.
        if FileManager.default.fileExists(atPath: vadModelPath) {
            arguments += ["--vad", "-vm", vadModelPath]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: logURL)
        // 녹음이나 사용자 작업보다 뒤로 미룬다. 한가할 때는 그대로 전체 속도로 돈다.
        process.qualityOfService = .utility

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw Failure.whisper(String(log.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        struct Output: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Item]
        }
        let data = try Data(contentsOf: base.appendingPathExtension("json"))
        return try JSONDecoder().decode(Output.self, from: data).transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(
                start: Double(item.offsets.from) / 1000, end: Double(item.offsets.to) / 1000,
                speaker: speaker, text: text)
        }
    }

    // MARK: - 화자 분리

    /// diarize.py로 조각을 목소리별로 묶어 "상대방1", "상대방2"…(파일은 "화자1"…)로 바꾼다.
    /// 실패하면 기록만 남기고 "상대방" 그대로 둔다.
    private static func splitSpeakers(_ segments: [Segment], wav: URL, work: URL, name: String) async -> [Segment] {
        do {
            let input = work.appendingPathComponent("segments.json")
            let spans = segments.map { ["start": $0.start, "end": $0.end] }
            try JSONSerialization.data(withJSONObject: spans).write(to: input)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [diarizeScript, wav.path, input.path, speakerModelPath]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .utility
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            guard status == 0 else { throw Failure.missing("diarize.py 종료 코드 \(status)") }

            struct Result: Decodable { let labels: [Int]; let speakers: Int }
            let result = try JSONDecoder().decode(Result.self, from: output.fileHandleForReading.readDataToEndOfFile())
            guard result.labels.count == segments.count else { return segments }
            audioLog.info("\(name) \(result.speakers, privacy: .public)명으로 분리")
            guard result.speakers > 1 else { return segments }
            return zip(segments, result.labels).map { segment, label in
                var segment = segment
                segment.speaker = "\(name)\(label)"
                return segment
            }
        } catch {
            audioLog.error("화자 분리 실패: \(error.localizedDescription, privacy: .public)")
            return segments
        }
    }

    // MARK: - 정리

    /// 스피커폰 소리가 마이크로 다시 들어와 같은 말이 "나"로도 적힌 경우를 지운다.
    private static func removeEcho(_ segments: [Segment]) -> [Segment] {
        let others = segments.filter { $0.speaker != "나" }
        return segments.filter { segment in
            guard segment.speaker == "나" else { return true }
            return !others.contains { other in
                other.start < segment.end + 1 && segment.start < other.end + 1 && similar(segment.text, other.text)
            }
        }
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let x = bigrams(a), y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.6
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count >= 2 else { return [] }
        return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
    }

    /// 시간순으로 놓고, 같은 사람이 이어서 말한 조각은 한 줄로 붙인다.
    private static func merge(_ segments: [Segment]) -> [Segment] {
        var lines: [Segment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = lines.last, last.speaker == segment.speaker,
               segment.start - last.end < 2, last.text.count + segment.text.count < 300 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                lines[lines.count - 1] = last
            } else {
                lines.append(segment)
            }
        }
        return lines
    }

    private static func render(_ lines: [Segment], title: String, legend: String) -> String {
        var text = "회의록 · \(title)\n\(legend)\n\n"
        if lines.isEmpty { text += "(알아들을 수 있는 말소리가 없었습니다)\n" }
        for line in lines {
            let s = Int(line.start)
            text += String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60)
            text += "\(line.speaker): \(line.text)\n"
        }
        return text
    }
}
