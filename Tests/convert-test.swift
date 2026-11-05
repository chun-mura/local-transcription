import AVFoundation
import Foundation

@main
enum ConvertTest {
    static func main() {
        run()
    }
}

private func run() {
let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
let frameCount = 4_800
guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
    fputs("入力バッファを作れませんでした\n", stderr)
    exit(1)
}
input.frameLength = AVAudioFrameCount(frameCount)
let left = input.floatChannelData![0]
let right = input.floatChannelData![1]
for index in 0..<frameCount {
    let mark: Float = index.isMultiple(of: 3) ? 1 : 0
    left[index] = mark
    right[index] = mark
}

let converter = FormatConverter(output: output)
converter.preferDecimation()
guard let decimated = converter.convert(input), let samples = decimated.floatChannelData else {
    fputs("間引きの出力がありません\n", stderr)
    exit(1)
}
if decimated.frameLength != AVAudioFrameCount(frameCount / 3) {
    fputs("フレーム数 \(decimated.frameLength)\n", stderr)
    exit(1)
}
if abs(samples[0][0]) < 0.4 {
    fputs("先頭サンプルが小さすぎます \(samples[0][0])\n", stderr)
    exit(1)
}

let streamed = FormatConverter(output: output)
guard let converted = streamed.convert(input), converted.frameLength > 0 else {
    fputs("変換器が音を返しませんでした\n", stderr)
    exit(1)
}

let speech = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
let mic = FormatConverter(output: speech)
var produced = 0
var quiet = 0
for _ in 0..<80 {
    let packet = microphonePacket(packed: false, frames: 512, amplitude: 0.5)
    guard let buffer = mic.convert(packet), buffer.frameLength > 0, let samples = buffer.int16ChannelData else {
        fputs("24bitのバッファが変換されませんでした\n", stderr)
        exit(1)
    }
    produced += 1
    var peak: Int32 = 0
    for index in 0..<Int(buffer.frameLength) {
        peak = max(peak, abs(Int32(samples[0][index])))
    }
    if peak < 8_000 {
        quiet += 1
    }
}
if produced != 80 || quiet > 0 {
    fputs("24bitの連続変換 produced=\(produced) quiet=\(quiet)\n", stderr)
    exit(1)
}
guard let packed = mic.convert(microphonePacket(packed: true, frames: 512, amplitude: 0.5)),
      packed.frameLength > 0,
      let packedSamples = packed.int16ChannelData else {
    fputs("24bitの詰め方が変わると変換が止まります\n", stderr)
    exit(1)
}
var packedPeak: Int32 = 0
for index in 0..<Int(packed.frameLength) {
    packedPeak = max(packedPeak, abs(Int32(packedSamples[0][index])))
}
if packedPeak < 8_000 {
    fputs("詰めた24bitの振幅が小さすぎます \(packedPeak)\n", stderr)
    exit(1)
}
if mic.isDecimating {
    fputs("変換できているのに間引きへ落ちました\n", stderr)
    exit(1)
}
guard let split = mic.convert(microphonePacket(packed: false, frames: 512, amplitude: 0.5, interleaved: false)),
      split.frameLength > 0,
      let splitSamples = split.int16ChannelData else {
    fputs("チャンネルが分かれた24bitを変換できませんでした\n", stderr)
    exit(1)
}
var splitPeak: Int32 = 0
for index in 0..<Int(split.frameLength) {
    splitPeak = max(splitPeak, abs(Int32(splitSamples[0][index])))
}
if splitPeak < 8_000 {
    fputs("分かれた24bitの振幅が小さすぎます \(splitPeak)\n", stderr)
    exit(1)
}
print("ok \(decimated.frameLength) \(converted.frameLength) \(produced) \(packedPeak) \(splitPeak)")
}

private func microphonePacket(packed: Bool, frames: Int, amplitude: Float, interleaved: Bool = true) -> AVAudioPCMBuffer {
    var flags: AudioFormatFlags = packed
        ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh
    if !interleaved {
        flags |= kAudioFormatFlagIsNonInterleaved
    }
    let bytesPerFrame: UInt32 = packed ? (interleaved ? 6 : 3) : (interleaved ? 8 : 4)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 24,
        mReserved: 0
    )
    let format = AVAudioFormat(streamDescription: &asbd)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let lists = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let planes = interleaved ? [lists[0].mData!] : [lists[0].mData!, lists[1].mData!]
    for raw in planes {
        if packed {
            let value = Int32((Double(amplitude) * 8_388_608).rounded())
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            let count = interleaved ? frames * 2 : frames
            for index in 0..<count {
                bytes[index * 3] = UInt8(truncatingIfNeeded: value)
                bytes[index * 3 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index * 3 + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        } else {
            let word = Int32((Double(amplitude) * 2_147_483_648).rounded())
            let samples = raw.assumingMemoryBound(to: Int32.self)
            let count = interleaved ? frames * 2 : frames
            for index in 0..<count {
                samples[index] = word
            }
        }
    }
    return buffer
}
