// Turns a screen recording into a looping GIF for the README, with no extra tools.
// Usage: swift scripts/demo/to-gif.swift <input.mov> <output.gif> [width] [fps]
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3])! : 960
let fps = args.count > 4 ? Double(args[4])! : 15

let asset = AVURLAsset(url: input)
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: width, height: width * 10)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let count = Int(duration * fps)
guard let gif = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
    fatalError("cannot write \(output.path)")
}
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for i in 0..<count {
    let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
    let image = try await generator.image(at: time).image
    CGImageDestinationAddImage(gif, image, frameProps)
}
guard CGImageDestinationFinalize(gif) else { fatalError("could not finish the GIF") }
print("Wrote \(output.path) (\(count) frames)")
