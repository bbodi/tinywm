// Writes the demo's background music: an original, upbeat synth-pop loop at 118 BPM, so the
// video needs no licensed track. Chords play alone under the title card, the beat starts when
// the windows open, and the end fades out.
// Usage: swift scripts/demo/music.swift <output.wav> <seconds | video to match>
import AVFoundation

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[1])
let seconds: Double
if let given = Double(args[2]) { seconds = given } else {
    seconds = try await AVURLAsset(url: URL(fileURLWithPath: args[2])).load(.duration).seconds
}
let rate = 44_100.0
let frames = Int(seconds * rate)
var left = [Float](repeating: 0, count: frames)
var right = [Float](repeating: 0, count: frames)

let bpm = 118.0
let beat = 60 / bpm
let bar = beat * 4
/// Bars before the drums come in.
let introBars = 2

func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

/// Adds `length` seconds of `voice` from `start`, panned from -1 (left) to 1 (right).
func add(at start: Double, length: Double, pan: Double = 0, gain: Double, _ voice: (Double) -> Double) {
    let first = Int(start * rate)
    let count = Int(length * rate)
    let l = Float(gain * min(1, 1 - pan)), r = Float(gain * min(1, 1 + pan))
    for i in 0..<count {
        let n = first + i
        guard n >= 0, n < frames else { continue }
        let v = Float(voice(Double(i) / rate))
        left[n] += v * l
        right[n] += v * r
    }
}

func saw(_ phase: Double) -> Double { 2 * (phase - phase.rounded(.down)) - 1 }
func square(_ phase: Double) -> Double { phase - phase.rounded(.down) < 0.5 ? 1 : -1 }

/// A deterministic noise source, so every run writes the same file.
var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
func noise() -> Double {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Double(seed % 20_000) / 10_000 - 1
}

/// One-pole low-pass filter state, for voices that need softening.
struct LowPass {
    var y = 0.0
    let a: Double
    init(cutoff: Double) { a = 1 - exp(-2 * .pi * cutoff / rate) }
    mutating func callAsFunction(_ x: Double) -> Double { y += a * (x - y); return y }
}

// MARK: Drums

func kick(at t: Double) {
    var phase = 0.0
    add(at: t, length: 0.35, gain: 0.9) { s in
        let f = 45 + 75 * exp(-s / 0.03)
        phase += f / rate
        return sin(2 * .pi * phase) * exp(-s / 0.12) + (s < 0.004 ? 0.3 * noise() : 0)
    }
}

func clap(at t: Double) {
    var hp = LowPass(cutoff: 900)
    add(at: t, length: 0.25, gain: 0.32) { s in
        let n = noise()
        // Three quick bursts, then a tail, as hands clapping.
        let bursts = s < 0.03 ? exp(-(s.truncatingRemainder(dividingBy: 0.01)) / 0.003) : 0
        return (n - hp(n)) * (bursts * 0.6 + exp(-s / 0.07))
    }
}

func hat(at t: Double, open: Bool, pan: Double) {
    var lp = LowPass(cutoff: 7000)
    add(at: t, length: open ? 0.3 : 0.06, pan: pan, gain: open ? 0.08 : 0.1) { s in
        let n = noise()
        return (n - lp(n)) * exp(-s / (open ? 0.09 : 0.018))
    }
}

// MARK: Tones

/// The chords: C, G, A minor, F. Each lasts one bar.
let chords: [[Int]] = [[60, 64, 67, 72], [59, 62, 67, 71], [60, 64, 69, 72], [60, 65, 69, 72]]
let roots = [36, 43, 45, 41]

/// How much the kick ducks the bass and pads at time `t`, which makes them pulse.
func pump(_ t: Double, drums: Bool) -> Double {
    guard drums else { return 1 }
    let since = t.truncatingRemainder(dividingBy: beat)
    return 1 - 0.55 * exp(-since / 0.11)
}

func pad(_ notes: [Int], at t: Double, drums: Bool) {
    for (i, note) in notes.enumerated() {
        var lp = LowPass(cutoff: 1800)
        var phases = [0.0, 0.0]
        let f = hz(note)
        add(at: t, length: bar + 0.25, pan: i.isMultiple(of: 2) ? -0.35 : 0.35, gain: 0.05) { s in
            phases[0] += f * 1.003 / rate
            phases[1] += f * 0.997 / rate
            let env = min(1, s / 0.08) * (s > bar ? exp(-(s - bar) / 0.08) : 1)
            return lp(saw(phases[0]) + saw(phases[1])) * env * pump(t + s, drums: drums)
        }
    }
}

func bass(_ root: Int, at t: Double) {
    // Eighth notes, with every other one an octave up.
    for step in 0..<8 {
        let note = root + (step % 2 == 1 ? 12 : 0)
        let start = t + Double(step) * beat / 2
        var lp = LowPass(cutoff: 600)
        var phase = 0.0
        let f = hz(note)
        add(at: start, length: beat / 2, gain: 0.32) { s in
            phase += f / rate
            let env = exp(-s / 0.16) * min(1, s / 0.004) * min(1, (beat / 2 - s) / 0.01)
            return lp(saw(phase) * 0.7 + square(phase) * 0.3) * env * pump(start + s, drums: true)
        }
    }
}

func arp(_ notes: [Int], at t: Double, bright: Double) {
    // Sixteenth notes up and down the chord, an octave higher.
    let order = [0, 1, 2, 3, 2, 1, 2, 3, 0, 1, 2, 3, 2, 1, 2, 3]
    for (step, i) in order.enumerated() {
        var lp = LowPass(cutoff: bright)
        var phase = 0.0
        let f = hz(notes[i] + 12)
        add(at: t + Double(step) * beat / 4, length: 0.22, pan: step.isMultiple(of: 2) ? -0.5 : 0.5, gain: 0.07) { s in
            phase += f / rate
            return lp(square(phase)) * exp(-s / 0.07) * min(1, s / 0.002)
        }
    }
}

/// A short hook over every second pass through the chords.
func lead(at t: Double, chord: Int) {
    let lines: [[(beat: Double, note: Int, length: Double)]] = [
        [(0, 76, 0.5), (0.5, 79, 0.5), (1, 81, 1), (2.5, 79, 0.5), (3, 76, 1)],
        [(0, 74, 0.5), (0.5, 79, 0.5), (1, 83, 1.5), (3, 81, 0.5), (3.5, 79, 0.5)],
        [(0, 76, 0.5), (0.5, 81, 0.5), (1, 84, 1), (2.5, 83, 0.5), (3, 81, 1)],
        [(0, 77, 0.5), (0.5, 81, 0.5), (1, 79, 1), (2, 77, 1), (3, 76, 1)],
    ]
    for n in lines[chord] {
        var lp = LowPass(cutoff: 3000)
        var phase = 0.0, vib = 0.0
        let f = hz(n.note), length = n.length * beat
        add(at: t + n.beat * beat, length: length + 0.15, gain: 0.07) { s in
            vib += 5.5 / rate
            phase += f * (1 + 0.004 * sin(2 * .pi * vib) * min(1, s / 0.2)) / rate
            let env = min(1, s / 0.01) * (s > length ? exp(-(s - length) / 0.05) : exp(-s / 1.2))
            return lp(saw(phase) * 0.5 + square(phase) * 0.5) * env
        }
    }
}

// MARK: Arrangement

let bars = Int(seconds / bar) + 1
for b in 0..<bars {
    let t = Double(b) * bar
    let c = b % 4
    let drums = b >= introBars
    pad(chords[c], at: t, drums: drums)
    // The arpeggio opens up as the intro ends.
    arp(chords[c], at: t, bright: drums ? 3500 : 1200 + Double(b) * 500)
    guard drums else { continue }
    bass(roots[c], at: t)
    if (b - introBars) / 4 % 2 == 1 { lead(at: t, chord: c) }
    for q in 0..<4 {
        let beatStart = t + Double(q) * beat
        kick(at: beatStart)
        if q % 2 == 1 { clap(at: beatStart) }
        hat(at: beatStart + beat / 2, open: q == 3, pan: 0.3)
        hat(at: beatStart + beat / 4, open: false, pan: -0.3)
        hat(at: beatStart + 3 * beat / 4, open: false, pan: -0.3)
    }
}
// A riser into the drums: noise that swells over the last intro bar.
do {
    var lp = LowPass(cutoff: 4000)
    add(at: Double(introBars - 1) * bar, length: bar, gain: 0.12) { s in
        let n = noise()
        return (n - lp(n)) * pow(s / bar, 2)
    }
}

// MARK: Mix

// A short fade in, a long fade out, then a soft limit so nothing clips.
let fadeIn = Int(0.05 * rate), fadeOut = Int(3.0 * rate)
var peak: Float = 0
for i in 0..<frames {
    var g: Float = 1
    if i < fadeIn { g = Float(i) / Float(fadeIn) }
    if i > frames - fadeOut { g = Float(frames - i) / Float(fadeOut) }
    left[i] = tanh(left[i] * 1.2) * g
    right[i] = tanh(right[i] * 1.2) * g
    peak = max(peak, abs(left[i]), abs(right[i]))
}
let scale = peak > 0 ? 0.89 / peak : 1

let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
buffer.frameLength = AVAudioFrameCount(frames)
for i in 0..<frames {
    buffer.floatChannelData![0][i] = left[i] * scale
    buffer.floatChannelData![1][i] = right[i] * scale
}
try? FileManager.default.removeItem(at: output)
// The file is finished when it closes, so it lives only inside this block.
do {
    let file = try AVAudioFile(forWriting: output, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}
print("Wrote \(output.path) (\(String(format: "%.1f", seconds)) s)")
