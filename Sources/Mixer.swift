import AVFoundation

/// 트랙별 파일을 시작 시각에 맞춰 한 파일로 합친다.
enum Mixer {
    static func mix(_ tracks: [Track], to output: URL) async throws {
        guard let origin = tracks.map(\.startTime).min() else { return }
        let composition = AVMutableComposition()

        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(
                      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: CMTimeSubtract(track.startTime, origin)
            )
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .m4a)
    }
}
