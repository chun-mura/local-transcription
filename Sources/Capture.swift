import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    var onBuffer: ((Speaker, AVAudioPCMBuffer) -> Void)?
    var onStopped: ((String) -> Void)?

    private let audioQueue = DispatchQueue(label: "local-transcription.system")
    private let microphoneQueue = DispatchQueue(label: "local-transcription.microphone")
    private var stream: SCStream?
    private var systemConverter: FormatConverter?
    private var microphoneConverter: FormatConverter?
    private var loggedMicrophoneFormat = false
    private let flagLock = NSLock()
    private var decimateMicrophone = false
    private var accepting = false
    private var intentionalStop = false

    private func setAccepting(_ open: Bool) {
        flagLock.lock()
        accepting = open
        intentionalStop = !open
        if open {
            loggedMicrophoneFormat = false
            decimateMicrophone = false
        }
        flagLock.unlock()
    }

    func preferDecimation() {
        flagLock.lock()
        decimateMicrophone = true
        flagLock.unlock()
        microphoneConverter?.preferDecimation()
    }

    func start(captureRate: Int, channels: Int, output: AVAudioFormat) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw EngineError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = captureRate
        configuration.channelCount = channels
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        systemConverter = FormatConverter(output: output)
        microphoneConverter = FormatConverter(output: output)
        setAccepting(true)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            setAccepting(false)
            self.stream = nil
            throw EngineError.captureFailed(error.localizedDescription)
        }
    }

    func stop() async {
        setAccepting(false)
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        audioQueue.sync {}
        microphoneQueue.sync {}
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        flagLock.lock()
        let open = accepting
        flagLock.unlock()
        guard open, let input = AudioBuffers.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:
            guard let output = systemConverter?.convert(input) else { return }
            onBuffer?(.system, output)
        case .microphone:
            if !loggedMicrophoneFormat {
                loggedMicrophoneFormat = true
                fputs("マイクの形式: \(input.format)\n", stderr)
            }
            flagLock.lock()
            let decimate = decimateMicrophone
            flagLock.unlock()
            if decimate {
                microphoneConverter?.preferDecimation()
            }
            guard let output = microphoneConverter?.convert(input) else { return }
            onBuffer?(.microphone, output)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        flagLock.lock()
        let intentional = intentionalStop
        flagLock.unlock()
        if intentional { return }
        onStopped?("音の取り込みが止まりました。\(error.localizedDescription)")
    }
}
