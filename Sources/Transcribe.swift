import AVFoundation
import CoreMedia
import Foundation
import Speech

final class LiveChannel: @unchecked Sendable {
    let speaker: Speaker
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let sampleRate: Double
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzeTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var frames: Int64 = 0
    private var lastFinalStart: CMTime?
    private var reportedLag = false

    var onFinal: (@Sendable (String, Double, Double) -> Void)?
    var onVolatile: (@Sendable (String) -> Void)?
    var onLag: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    init(speaker: Speaker, locale: Locale, format: AVAudioFormat) {
        self.speaker = speaker
        self.format = format
        self.sampleRate = format.sampleRate
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
    }

    func prepare() async throws {
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        storeContinuation(continuation)

        listenTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    self.consume(result)
                }
            } catch {
                self.onFailure?("\(self.speaker.label)の認識が止まりました。\(error.localizedDescription)")
            }
        }
        analyzeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.analyzer.start(inputSequence: stream)
            } catch {
                self.onFailure?("\(self.speaker.label)の認識を開始できませんでした。\(error.localizedDescription)")
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let start = frames
        frames += Int64(buffer.frameLength)
        let continuation = continuation
        lock.unlock()
        let time = CMTime(value: start, timescale: CMTimeScale(sampleRate.rounded()))
        continuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
    }

    func audioTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    func finish() async {
        let continuation = takeContinuation()
        continuation?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await analyzeTask?.value
        await waitForListener()
        listenTask?.cancel()
    }

    private func storeContinuation(_ continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func takeContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        return value
    }

    private func waitForListener() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [listenTask] in
                await listenTask?.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        lock.lock()
        let fed = sampleRate > 0 ? Double(frames) / sampleRate : 0
        let alreadyReported = reportedLag
        lock.unlock()
        if speaker == .microphone, !alreadyReported, end.isFinite, fed - end > 2 {
            lock.lock()
            reportedLag = true
            lock.unlock()
            onLag?()
        }
        guard !text.isEmpty else { return }
        if result.isFinal {
            lock.lock()
            if let lastFinalStart, CMTimeCompare(lastFinalStart, result.range.start) == 0 {
                lock.unlock()
                return
            }
            lastFinalStart = result.range.start
            lock.unlock()
            let start = CMTimeGetSeconds(result.range.start)
            let endSeconds = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            let rangeStart = start.isFinite ? start : 0
            let rangeEnd = endSeconds.isFinite ? max(endSeconds, rangeStart) : rangeStart
            onFinal?(text, rangeStart, rangeEnd)
            onVolatile?("")
        } else {
            onVolatile?(text)
        }
    }
}

enum EngineError: LocalizedError {
    case microphoneDenied
    case screenDenied(String)
    case japaneseUnavailable
    case modelUnsupported
    case modelNotInstalled
    case formatUnavailable
    case noDisplay
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクの使用が許可されていません。システム設定の「マイク」でこのアプリを許可してください。"
        case .screenDenied(let detail):
            let base = "画面収録が許可されていません。システム設定の「画面収録とシステムオーディオ録音」でこのアプリを許可してから、もう一度開いてください。"
            return detail.isEmpty ? base : "\(base)（\(detail)）"
        case .japaneseUnavailable:
            return "このMacでは日本語の音声認識が使えません。"
        case .modelUnsupported:
            return "日本語の認識モデルがこのMacに対応していません。"
        case .modelNotInstalled:
            return "日本語の認識モデルを導入できませんでした。"
        case .formatUnavailable:
            return "認識に渡す音声形式が見つかりませんでした。"
        case .noDisplay:
            return "取り込みに使うディスプレイが見つかりませんでした。"
        case .captureFailed(let detail):
            return "音の取り込みを開始できませんでした。\(detail)"
        }
    }
}

enum SpeechSetup {
    static func japaneseLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja_JP"))
    }

    static func installModel(for modules: [SpeechTranscriber], report: @escaping @Sendable (String) -> Void) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .unsupported:
            throw EngineError.modelUnsupported
        default:
            break
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            let again = await AssetInventory.status(forModules: modules)
            if again == .installed { return }
            throw EngineError.modelNotInstalled
        }
        let progress = Task {
            while !Task.isCancelled {
                let percent = Int((request.progress.fractionCompleted * 100).rounded())
                report("日本語の認識モデルをダウンロードしています（\(percent)%）")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { progress.cancel() }
        try await request.downloadAndInstall()
    }

    static func chooseFormat(for module: SpeechTranscriber) async -> AVAudioFormat? {
        let formats = await module.availableCompatibleAudioFormats
        if let match = formats.first(where: {
            $0.sampleRate == 16_000 && $0.channelCount == 1 && $0.commonFormat == .pcmFormatFloat32 && !$0.isInterleaved
        }) {
            return match
        }
        if let match = formats.first(where: { $0.sampleRate == 16_000 && $0.channelCount == 1 }) {
            return match
        }
        if let first = formats.first {
            return first
        }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }
}
