// Turns a screen recording into a 1080p H.264 MP4 for the website, with no extra tools.
// The bit rate is low, since the screen is mostly still, so the file stays under 10 MB: the
// largest video GitHub takes on a free plan.
// Usage: swift scripts/demo/to-mp4.swift <input.mov> <output.mp4> [bits per second]
import AVFoundation

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[2])
let bitRate = args.count > 3 ? Int(args[3])! : 1_500_000
try? FileManager.default.removeItem(at: output)

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
guard let track = try await asset.loadTracks(withMediaType: .video).first else { fatalError("no video in \(args[1])") }
let size = try await track.load(.naturalSize)
let width = 1920, height = Int((Double(width) * size.height / size.width / 2).rounded()) * 2

let reader = try AVAssetReader(asset: asset)
let source = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
reader.add(source)

let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalDurationKey: 2,
    ],
])
input.expectsMediaDataInRealTime = false
writer.add(input)
writer.shouldOptimizeForNetworkUse = true

reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let done = DispatchSemaphore(value: 0)
input.requestMediaDataWhenReady(on: DispatchQueue(label: "to-mp4")) {
    while input.isReadyForMoreMediaData {
        guard let sample = source.copyNextSampleBuffer() else {
            input.markAsFinished()
            done.signal()
            return
        }
        input.append(sample)
    }
}
done.wait()
await writer.finishWriting()
guard writer.status == .completed else { fatalError("could not write \(output.path): \(String(describing: writer.error))") }
print("Wrote \(output.path)")
