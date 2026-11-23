// Original soundtrack for the demo video, synthesized from scratch (no
// samples, no third-party music): a calm pad and arpeggio, a riser, then a
// big-beat style drop with kick, snare, hats and a distorted bass, and a
// calm ending. Usage: swift scripts/demo-music.swift out.wav [seconds] [drop]
import Foundation

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "demo-music.wav"
let duration = args.count > 2 ? Double(args[2]) ?? 44 : 44
let drop = args.count > 3 ? Double(args[3]) ?? 14 : 14
let rate = 44_100.0
let n = Int(duration * rate)
var left = [Float](repeating: 0, count: n)
var right = [Float](repeating: 0, count: n)

let bpm = 128.0
let beat = 60 / bpm
var seed: UInt64 = 0x5EED
func noise() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 1) % 2_000_000) / 1_000_000 - 1
}
func add(_ i: Int, _ v: Double, pan: Double = 0) {
    guard i >= 0, i < n else { return }
    left[i] += Float(v * (1 - max(0, pan)))
    right[i] += Float(v * (1 + min(0, pan)))
}
func midi(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

// Chords (A minor - F - C - G), 2 bars each.
let chords: [[Double]] = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
let roots: [Double] = [45, 41, 36, 43]
let barLength = beat * 4
func chordIndex(_ t: Double) -> Int { Int(t / (barLength * 2)) % chords.count }

let end = duration - 4  // calm outro starts here

// Pad: detuned sines with slow swell, all the way through.
for i in 0..<n {
    let t = Double(i) / rate
    let c = chords[chordIndex(t)]
    var v = 0.0
    for note in c {
        let f = midi(note)
        v += sin(2 * .pi * f * t) + 0.6 * sin(2 * .pi * f * 1.003 * t) + 0.3 * sin(2 * .pi * f * 2.001 * t)
    }
    let swell = min(1, t / 3) * (t > duration - 2 ? max(0, (duration - t) / 2) : 1)
    let level = t < drop ? 0.05 : (t < end ? 0.035 : 0.05)
    add(i, v * level * swell / 3, pan: 0.2 * sin(t * 0.5))
}

// Arpeggio plucks (8ths), calm part and outro.
var t0 = 0.0
var step = 0
while t0 < duration {
    defer { t0 += beat / 2; step += 1 }
    guard t0 < drop - 2 || t0 >= end else { continue }
    let c = chords[chordIndex(t0)]
    let note = c[step % 3] + 12 * Double((step / 3) % 2)
    let f = midi(note)
    let start = Int(t0 * rate)
    for k in 0..<Int(0.4 * rate) {
        let t = Double(k) / rate
        let env = exp(-t * 9)
        add(start + k, 0.09 * env * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)), pan: step % 2 == 0 ? -0.3 : 0.3)
    }
}

// Riser: filtered noise sweep + snare roll into the drop.
let riserStart = drop - 2
for i in Int(riserStart * rate)..<Int(drop * rate) {
    let t = Double(i) / rate - riserStart
    let p = t / 2
    add(i, noise() * 0.12 * p * p)
    add(i, 0.05 * p * sin(2 * .pi * (200 + 1800 * p * p) * t))
}
var rollTime = riserStart
var rollStep = beat / 2
while rollTime < drop {
    let start = Int(rollTime * rate)
    let level = 0.15 + 0.35 * (rollTime - riserStart) / 2
    for k in 0..<Int(0.12 * rate) {
        let t = Double(k) / rate
        add(start + k, level * exp(-t * 30) * (noise() * 0.8 + 0.4 * sin(2 * .pi * 190 * t)))
    }
    rollTime += rollStep
    rollStep = max(beat / 8, rollStep * 0.8)
}

// Drums and bass from the drop to the outro.
func kick(_ at: Double, _ level: Double = 0.9) {
    let start = Int(at * rate)
    var phase = 0.0
    for k in 0..<Int(0.35 * rate) {
        let t = Double(k) / rate
        let f = 45 + 110 * exp(-t * 28)
        phase += 2 * .pi * f / rate
        add(start + k, level * exp(-t * 7) * tanh(1.8 * sin(phase)))
    }
}
func snare(_ at: Double, _ level: Double = 0.45) {
    let start = Int(at * rate)
    for k in 0..<Int(0.22 * rate) {
        let t = Double(k) / rate
        add(start + k, level * (exp(-t * 18) * noise() * 0.9 + exp(-t * 30) * sin(2 * .pi * 185 * t) * 0.6), pan: -0.05)
    }
}
func hat(_ at: Double, _ level: Double, open: Bool = false) {
    let start = Int(at * rate)
    var prev = 0.0
    for k in 0..<Int((open ? 0.18 : 0.05) * rate) {
        let t = Double(k) / rate
        let x = noise()
        add(start + k, level * exp(-t * (open ? 14 : 60)) * (x - prev), pan: 0.25)  // crude high-pass
        prev = x
    }
}

// Break pattern over two bars (16ths): kick, snare, hats.
let kicks: Set<Int> = [0, 6, 10, 16, 22, 26, 27]
let snares: Set<Int> = [4, 12, 20, 28, 31]
var sixteenth = 0
var time = drop
while time < end {
    let s = sixteenth % 32
    if kicks.contains(s) { kick(time) }
    if snares.contains(s) { snare(time, s == 31 ? 0.25 : 0.45) }
    hat(time, s % 2 == 0 ? 0.16 : 0.09, open: s % 8 == 6)
    time += beat / 4
    sixteenth += 1
}
kick(end, 1)  // final hit

// Distorted bass: root notes, syncopated 8ths, through a soft clipper.
time = drop
var eighth = 0
let bassPattern: [Double] = [0, 0, 12, 0, 0, 7, 0, 12]
while time < end {
    let root = roots[chordIndex(time)]
    let f = midi(root + bassPattern[eighth % 8] - 12)
    let start = Int(time * rate)
    var phase = 0.0
    for k in 0..<Int(beat / 2 * 0.9 * rate) {
        let t = Double(k) / rate
        phase += f / rate
        let saw = 2 * (phase - floor(phase + 0.5))
        add(start + k, 0.22 * exp(-t * 3) * tanh(3 * saw))
    }
    time += beat / 2
    eighth += 1
}

// Master: soft limiter and fades, then 16-bit stereo WAV.
let peak = max(left.map { abs($0) }.max() ?? 1, right.map { abs($0) }.max() ?? 1)
let gain = 0.9 / max(0.001, Double(peak))
var pcm = Data(capacity: n * 4)
for i in 0..<n {
    let t = Double(i) / rate
    let fade = min(1, t / 0.5) * min(1, (duration - t) / 1.5)
    for ch in [left[i], right[i]] {
        let v = tanh(Double(ch) * gain * 1.2) * fade
        var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
        withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
    }
}
func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
var wav = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(2)) + le(UInt32(44100)) + le(UInt32(44100 * 4))
wav += le(UInt16(4)) + le(UInt16(16)) + Data("data".utf8) + le(UInt32(pcm.count)) + pcm
try! wav.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(duration) s, drop at \(drop) s)")
