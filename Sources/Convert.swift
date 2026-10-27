import AVFoundation

/// マイクの本来の形式を、認識へ渡す形式へバッファ単位で変換する。
/// 変換器が音を溜めて出さないときは、整数倍の間引きに切り替える。
final class FormatConverter: @unchecked Sendable {
    let output: AVAudioFormat
    private var rateConverter: AVAudioConverter?
    private var rateConverterKey: String?
    private var sameRateConverter: AVAudioConverter?
    private var sameRateKey: String?
    private var outputConverter: AVAudioConverter?
    private var fedSeconds: Double = 0
    private var produced = false
    private var forceDecimation = false
    private let lock = NSLock()

    init(output: AVAudioFormat) {
        self.output = output
    }

    func preferDecimation() {
        lock.lock()
        forceDecimation = true
        lock.unlock()
    }

    var isDecimating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return forceDecimation
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        if sameFormat(input.format, output) {
            return input
        }

        lock.lock()
        let decimate = forceDecimation
        lock.unlock()

        if decimate {
            return decimated(input)
        }

        guard let converted = convertWithRateConverter(input) else { return nil }
        if converted.frameLength > 0 {
            lock.lock()
            produced = true
            lock.unlock()
            return converted
        }

        lock.lock()
        fedSeconds += Double(input.frameLength) / input.format.sampleRate
        let stalled = fedSeconds > 0.5 && !produced
        if stalled {
            forceDecimation = true
            rateConverter = nil
            rateConverterKey = nil
        }
        lock.unlock()

        if stalled {
            return decimated(input)
        }
        return nil
    }

    private func convertWithRateConverter(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let key = formatKey(input.format)
        lock.lock()
        if rateConverterKey != key {
            rateConverter = makeConverter(from: input.format, to: output)
            rateConverterKey = key
            fedSeconds = 0
            produced = false
        }
        let converter = rateConverter
        lock.unlock()
        guard let converter else { return nil }
        return pull(converter, input: input, output: output)
    }

    private func decimated(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = input.format.sampleRate / output.sampleRate
        let step = Int(ratio.rounded())
        guard step >= 1, abs(Double(step) - ratio) < 0.01 else {
            return convertWithRateConverter(input)
        }
        if step == 1 {
            return convertSameRate(input, to: output)
        }
        guard let mixed = mixToFloat(input) else { return nil }
        let outFrames = mixed.count / step
        guard outFrames > 0,
              let pacedFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: output.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let paced = AVAudioPCMBuffer(pcmFormat: pacedFormat, frameCapacity: AVAudioFrameCount(outFrames)),
              let destination = paced.floatChannelData
        else { return nil }
        paced.frameLength = AVAudioFrameCount(outFrames)
        for index in 0..<outFrames {
            destination[0][index] = mixed[index * step]
        }
        if sameFormat(paced.format, output) {
            return paced
        }
        return convertSameRate(paced, to: output)
    }

    private func mixToFloat(_ input: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var mixed = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        if let data = input.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mixed[frame] += data[channel][frame] * scale
                }
            }
            return mixed
        }
        if let data = input.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mixed[frame] += Float(data[channel][frame]) / 32768 * scale
                }
            }
            return mixed
        }
        if let data = input.int32ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mixed[frame] += Float(data[channel][frame]) / 2_147_483_648 * scale
                }
            }
            return mixed
        }
        guard input.format.isInterleaved, let raw = input.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        if input.format.commonFormat == .pcmFormatFloat32 {
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mixed[frame] = sum * scale
            }
            return mixed
        }
        if input.format.commonFormat == .pcmFormatInt16 {
            let samples = raw.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += Float(samples[frame * channels + channel]) / 32768
                }
                mixed[frame] = sum * scale
            }
            return mixed
        }
        return nil
    }

    private func convertSameRate(_ input: AVAudioPCMBuffer, to output: AVAudioFormat) -> AVAudioPCMBuffer? {
        if sameFormat(input.format, output) {
            return input
        }
        let key = formatKey(input.format) + ">" + formatKey(output)
        lock.lock()
        if sameRateKey != key {
            sameRateConverter = makeConverter(from: input.format, to: output)
            sameRateKey = key
        }
        let converter = sameRateConverter
        lock.unlock()
        guard let converter else { return nil }
        return pull(converter, input: input, output: output)
    }

    private func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.min.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        converter.downmix = true
        return converter
    }

    private func pull(_ converter: AVAudioConverter, input: AVAudioPCMBuffer, output: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * max(ratio, 1))) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || error != nil {
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    private func sameFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func formatKey(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
    }
}

enum AudioBuffers {
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}
