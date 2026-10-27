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
print("ok \(decimated.frameLength) \(converted.frameLength)")
}
