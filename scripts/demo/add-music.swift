// Puts a music track under a video without encoding the video again.
// Usage: swift scripts/demo/add-music.swift <video.mp4> <music.wav> <output.mp4>
import AVFoundation

let args = CommandLine.arguments
let video = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let output = URL(fileURLWithPath: args[3])

// An MP4 can't hold the WAV's raw audio, so it becomes AAC first.
let aac = FileManager.default.temporaryDirectory.appendingPathComponent("tinywm-music-\(getpid()).m4a")
try? FileManager.default.removeItem(at: aac)
guard let toAAC = AVAssetExportSession(asset: AVURLAsset(url: URL(fileURLWithPath: args[2])), presetName: AVAssetExportPresetAppleM4A) else {
    fatalError("cannot encode \(args[2])")
}
try await toAAC.export(to: aac, as: .m4a)
defer { try? FileManager.default.removeItem(at: aac) }

let music = AVURLAsset(url: aac)
let duration = try await video.load(.duration)
let composition = AVMutableComposition()
guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
      let musicTrack = try await music.loadTracks(withMediaType: .audio).first,
      let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    fatalError("missing a video or audio track")
}
let range = CMTimeRange(start: .zero, duration: duration)
try v.insertTimeRange(range, of: videoTrack, at: .zero)
let musicLength = try await music.load(.duration)
try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, musicLength)), of: musicTrack, at: .zero)

try? FileManager.default.removeItem(at: output)
guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
    fatalError("cannot write \(output.path)")
}
export.shouldOptimizeForNetworkUse = true
try await export.export(to: output, as: .mp4)
print("Wrote \(output.path)")
