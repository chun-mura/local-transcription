import AVFoundation
import CoreMedia
import Foundation

@main
enum MixTest {
    static func main() throws {
        try checkOverlap()
        try checkGap()
        try checkQuietOverlap()
        try checkEarlierArrival()
        try checkDistantClock()
    }
}

private let rate = 16_000.0

private func checkOverlap() throws {
    let url = try makeMix { mix in
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 1.0), at: time(0), duration: time(1))
        mix.add(speaker: .microphone, buffer: tone(0.25, seconds: 1.0), at: time(0.5), duration: time(1))
    }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let samples = try readSamples(url)
    expect(samples.count, frames(1.5))
    expectRegion(samples, from: 0, to: 0.5, value: 0.5)
    expectRegion(samples, from: 0.5, to: 1.0, value: 0.375)
    expectRegion(samples, from: 1.0, to: 1.5, value: 0.25)
}

private func checkGap() throws {
    let url = try makeMix { mix in
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 0.5), at: time(0), duration: time(0.5))
        mix.add(speaker: .system, buffer: nil, at: time(0.5), duration: time(0.5))
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 0.5), at: time(1), duration: time(0.5))
        mix.add(speaker: .microphone, buffer: tone(0.25, seconds: 0.5), at: time(0), duration: time(0.5))
    }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let samples = try readSamples(url)
    expect(samples.count, frames(1.5))
    expectRegion(samples, from: 0, to: 0.5, value: 0.375)
    expectRegion(samples, from: 0.5, to: 1.0, value: 0)
    expectRegion(samples, from: 1.0, to: 1.5, value: 0.5)
}

private func checkQuietOverlap() throws {
    let url = try makeMix { mix in
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 0.25), at: time(0), duration: time(0.25))
        mix.add(speaker: .microphone, buffer: tone(0.005, seconds: 0.25), at: time(0), duration: time(0.25))
    }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let samples = try readSamples(url)
    expect(samples.count, frames(0.25))
    expectRegion(samples, from: 0, to: 0.25, value: 0.505)
}

private func checkEarlierArrival() throws {
    let url = try makeMix { mix in
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 0.5), at: time(10), duration: time(0.5))
        mix.add(speaker: .microphone, buffer: tone(0.25, seconds: 0.5), at: time(9.5), duration: time(0.5))
    }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let samples = try readSamples(url)
    expect(samples.count, frames(1))
    expectRegion(samples, from: 0, to: 0.5, value: 0.25)
    expectRegion(samples, from: 0.5, to: 1, value: 0.5)
}

private func checkDistantClock() throws {
    let url = try makeMix { mix in
        mix.add(speaker: .system, buffer: tone(0.5, seconds: 0.25), at: time(1_000), duration: time(0.25))
        mix.add(speaker: .microphone, buffer: tone(0.25, seconds: 0.25), at: time(0), duration: time(0.25))
    }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let samples = try readSamples(url)
    expect(samples.count, frames(0.25))
    expectRegion(samples, from: 0, to: 0.25, value: 0.5)
}

private func makeMix(_ fill: (ConversationMix) -> Void) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mix-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("audio.wav")
    var mix: ConversationMix? = try ConversationMix(url: url, sampleRate: rate)
    fill(mix!)
    mix?.finish()
    mix = nil
    return url
}

private func tone(_ value: Float, seconds: Double) -> AVAudioPCMBuffer {
    let count = frames(seconds)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    let samples = buffer.floatChannelData![0]
    for index in 0..<count {
        samples[index] = value
    }
    return buffer
}

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 16_000)
}

private func frames(_ seconds: Double) -> Int {
    Int((seconds * rate).rounded())
}

private func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let chunk = AVAudioFrameCount(4_096)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
        fail("読み取りバッファを作れません")
    }
    var samples: [Float] = []
    while file.framePosition < file.length {
        let remaining = AVAudioFrameCount(file.length - file.framePosition)
        try file.read(into: buffer, frameCount: min(chunk, remaining))
        guard let data = buffer.floatChannelData else { fail("floatではありません") }
        let got = Int(buffer.frameLength)
        if got == 0 { break }
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
    }
    return samples
}

private func expectRegion(_ samples: [Float], from: Double, to: Double, value: Float) {
    let start = frames(from)
    let end = frames(to)
    guard start >= 0, end <= samples.count, start < end else {
        fail("範囲がはみ出しています \(from)-\(to) count \(samples.count)")
    }
    for index in start..<end {
        if abs(samples[index] - value) > 0.001 {
            fail("\(from)-\(to) の \(index) が \(samples[index])（期待 \(value)）")
        }
    }
}

private func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}
