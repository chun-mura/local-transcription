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
        let source = standardFloat(input) ?? input
        if sameFormat(source.format, output) {
            return source
        }

        lock.lock()
        let decimate = forceDecimation
        lock.unlock()

        if decimate {
            return decimated(source)
        }

        switch convertWithRateConverter(source) {
        case .produced(let converted):
            noteProduced()
            return converted
        case .starved:
            return stall(source)
        case .failed:
            invalidateRateConverter()
            if case .produced(let converted) = convertWithRateConverter(source) {
                noteProduced()
                return converted
            }
            invalidateRateConverter()
            return stall(source)
        }
    }

    private func noteProduced() {
        lock.lock()
        fedSeconds = 0
        lock.unlock()
    }

    private func stall(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        fedSeconds += Double(source.frameLength) / source.format.sampleRate
        let giveUp = fedSeconds > 0.5
        if giveUp {
            forceDecimation = true
            rateConverter = nil
            rateConverterKey = nil
        }
        lock.unlock()
        if giveUp {
            return decimated(source)
        }
        return nil
    }

    private func invalidateRateConverter() {
        lock.lock()
        rateConverter = nil
        rateConverterKey = nil
        lock.unlock()
    }

    private func convertWithRateConverter(_ input: AVAudioPCMBuffer) -> Conversion {
        let key = formatKey(input.format)
        lock.lock()
        let reusable = rateConverterKey == key && rateConverter?.inputFormat.isEqual(input.format) == true
        if !reusable {
            rateConverter = makeConverter(from: input.format, to: output)
            rateConverterKey = key
        }
        let converter = rateConverter
        lock.unlock()
        guard let converter else { return .failed }
        return pull(converter, input: input, output: output)
    }

    private func decimated(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = input.format.sampleRate / output.sampleRate
        let step = Int(ratio.rounded())
        guard step >= 1, abs(Double(step) - ratio) < 0.01 else {
            guard case .produced(let converted) = convertWithRateConverter(input) else { return nil }
            return converted
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

    /// 24bit など変換器が受け付けない整数を、同じサンプルレートの Float32 にする。
    /// Studio 24c は 4 バイトに収めた 24bit で届き、形式の細部がバッファごとに違う。
    private func standardFloat(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.format.commonFormat == .otherFormat else { return nil }
        let asbd = input.format.streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              asbd.mBitsPerChannel == 24
        else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = Int(input.frameLength)
        guard channels > 0, frames > 0 else { return nil }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let bytesPerSample = nonInterleaved ? bytesPerFrame : bytesPerFrame / channels
        guard bytesPerSample == 3 || bytesPerSample == 4 else { return nil }
        let highAligned = asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength),
           let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = input.frameLength
        let lists = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        if nonInterleaved {
            guard lists.count >= channels else { return nil }
            for channel in 0..<channels {
                guard let data = lists[channel].mData else { return nil }
                let samples = destination[channel]
                for frame in 0..<frames {
                    samples[frame] = decode24(
                        data,
                        sampleIndex: frame,
                        bytesPerSample: bytesPerSample,
                        highAligned: highAligned,
                        bigEndian: bigEndian
                    )
                }
            }
        } else {
            guard let data = lists.first?.mData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    destination[channel][frame] = decode24(
                        data,
                        sampleIndex: frame * channels + channel,
                        bytesPerSample: bytesPerSample,
                        highAligned: highAligned,
                        bigEndian: bigEndian
                    )
                }
            }
        }
        return buffer
    }

    private func decode24(
        _ data: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bytesPerSample: Int,
        highAligned: Bool,
        bigEndian: Bool
    ) -> Float {
        if bytesPerSample == 4 {
            var word = data.load(fromByteOffset: sampleIndex * 4, as: Int32.self)
            if bigEndian {
                word = Int32(bigEndian: word)
            }
            if highAligned {
                return Float(word) / 2_147_483_648
            }
            var value = word & 0x00FF_FFFF
            if value >= 0x0080_0000 {
                value -= 0x0100_0000
            }
            return Float(value) / 8_388_608
        }
        let offset = sampleIndex * 3
        let b0 = Int32(data.load(fromByteOffset: offset, as: UInt8.self))
        let b1 = Int32(data.load(fromByteOffset: offset + 1, as: UInt8.self))
        let b2 = Int32(data.load(fromByteOffset: offset + 2, as: UInt8.self))
        var value = bigEndian ? (b0 << 16) | (b1 << 8) | b2 : b0 | (b1 << 8) | (b2 << 16)
        if value >= 0x0080_0000 {
            value -= 0x0100_0000
        }
        return Float(value) / 8_388_608
    }

    private func mixToFloat(_ input: AVAudioPCMBuffer) -> [Float]? {
        let input = standardFloat(input) ?? input
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
        guard case .produced(let buffer) = pull(converter, input: input, output: output) else { return nil }
        return buffer
    }

    private func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.min.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        converter.downmix = true
        return converter
    }

    private func pull(_ converter: AVAudioConverter, input: AVAudioPCMBuffer, output: AVAudioFormat) -> Conversion {
        let ratio = output.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * max(ratio, 1))) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return .failed }
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
            return .failed
        }
        if buffer.frameLength == 0 {
            return .starved
        }
        return .produced(buffer)
    }

    private func sameFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func formatKey(_ format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        let layout = format.channelLayout?.layoutTag ?? 0
        return "\(asbd.mSampleRate)-\(asbd.mFormatID)-\(asbd.mFormatFlags)-\(asbd.mBytesPerPacket)-\(asbd.mFramesPerPacket)-\(asbd.mBytesPerFrame)-\(asbd.mChannelsPerFrame)-\(asbd.mBitsPerChannel)-\(layout)"
    }
}

private enum Conversion {
    case produced(AVAudioPCMBuffer)
    case starved
    case failed
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
