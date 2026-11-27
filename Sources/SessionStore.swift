import AVFoundation
import CoreMedia
import Foundation

enum Speaker: String, Sendable {
    case system
    case microphone

    var label: String {
        switch self {
        case .system: "相手"
        case .microphone: "自分"
        }
    }
}

struct TranscriptSegment: Equatable {
    var speaker: Speaker
    var wall: Date
    var start: Double
    var end: Double
    var text: String
}

struct TranscriptLine: Equatable {
    var time: String
    var label: String
    var text: String

    init(time: String, label: String, text: String) {
        self.time = time
        self.label = label
        self.text = text
    }

    init?(_ line: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let timeStart = line.index(after: line.startIndex)
        time = String(line[timeStart..<close])
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        if let tab = rest.firstIndex(of: "\t") {
            label = rest[..<tab].trimmingCharacters(in: .whitespaces)
            text = rest[rest.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            return
        }
        if rest.hasPrefix("自分 ") || rest == "自分" {
            label = "自分"
        } else if rest.hasPrefix("相手 ") || rest == "相手" {
            label = "相手"
        } else {
            return nil
        }
        text = rest.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
    }
}

private struct MixChunk {
    var speaker: Speaker
    var startSecond: Double
    var samples: [Float]
}

/// 相手と自分を、取り込み時刻を揃えたモノラルへ重ねる。
final class ConversationMix {
    private let format: AVAudioFormat
    private let sampleRate: Double
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var origin: Double?
    private var heardUntil: [Speaker: Double] = [:]
    private var pending: [MixChunk] = []
    private var committedFrames: Int64 = 0
    private var closed = false
    private var loggedLateDrop = false
    private var loggedDistantClock = false
    private var loggedWriteError = false
    private let skewLimit = 20.0
    private let originSlack = 30.0

    init(url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SessionsRootError.unavailable
        }
        self.format = format
        self.sampleRate = sampleRate
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func add(speaker: Speaker, buffer: AVAudioPCMBuffer?, at time: CMTime, duration: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let samples = buffer.flatMap { Self.floats(from: $0) } ?? []
        let bufferSpan = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let span = max(Self.positiveSeconds(duration) ?? 0, bufferSpan)
        guard let start = timelineStart(speaker: speaker, time: time) else { return }
        heardUntil[speaker] = max(heardUntil[speaker] ?? 0, start + span)
        if !samples.isEmpty {
            place(speaker: speaker, samples: samples, at: start)
        }
        flush(final: false)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        flush(final: true)
        file = nil
    }

    private func timelineStart(speaker: Speaker, time: CMTime) -> Double? {
        guard let seconds = Self.finiteSeconds(time) else {
            return heardUntil[speaker] ?? 0
        }
        guard committedFrames == 0 else {
            let start = seconds - (origin ?? seconds)
            if start < -originSlack {
                noteDistantClock()
                return nil
            }
            return start
        }
        if let origin {
            if seconds < origin {
                let shift = origin - seconds
                if shift > originSlack {
                    noteDistantClock()
                    return nil
                }
                self.origin = seconds
                for index in pending.indices {
                    pending[index].startSecond += shift
                }
                for key in heardUntil.keys {
                    heardUntil[key]! += shift
                }
            }
        } else {
            origin = seconds
        }
        return seconds - (origin ?? seconds)
    }

    private func place(speaker: Speaker, samples: [Float], at start: Double) {
        let startFrame = frame(start)
        guard startFrame >= committedFrames else {
            noteLateDrop()
            let skip = Int(committedFrames - startFrame)
            guard skip < samples.count else { return }
            let kept = Array(samples[skip...])
            let keptStart = sampleRate > 0 ? Double(committedFrames) / sampleRate : 0
            pending.append(MixChunk(speaker: speaker, startSecond: keptStart, samples: kept))
            return
        }
        pending.append(MixChunk(speaker: speaker, startSecond: start, samples: samples))
    }

    private func noteLateDrop() {
        guard !loggedLateDrop else { return }
        loggedLateDrop = true
        fputs("確定済みの位置へ遅れて届いた音を捨てました\n", stderr)
    }

    private func noteDistantClock() {
        guard !loggedDistantClock else { return }
        loggedDistantClock = true
        fputs("取り込み時刻が離れすぎているため、その音は重ねませんでした\n", stderr)
    }

    private func flush(final: Bool) {
        let commitSeconds: Double
        if final {
            let heard = heardUntil.values.max() ?? 0
            let pendingEnd = pending.reduce(into: 0.0) { end, chunk in
                let span = sampleRate > 0 ? Double(chunk.samples.count) / sampleRate : 0
                end = max(end, chunk.startSecond + span)
            }
            commitSeconds = max(heard, pendingEnd)
        } else {
            guard let system = heardUntil[.system], let microphone = heardUntil[.microphone] else { return }
            let slow = min(system, microphone)
            let fast = max(system, microphone)
            commitSeconds = fast - slow > skewLimit ? fast - skewLimit : slow
        }
        let commitFrame = max(committedFrames, frame(commitSeconds))
        var cursor = committedFrames
        let step = Int64(max(sampleRate, 1).rounded())
        while cursor < commitFrame {
            let end = min(commitFrame, cursor + max(step, 1))
            write(from: cursor, to: end)
            cursor = end
        }
    }

    private func write(from start: Int64, to end: Int64) {
        let count = Int(end - start)
        guard count > 0 else {
            committedFrames = end
            return
        }
        var system = [Float](repeating: 0, count: count)
        var microphone = [Float](repeating: 0, count: count)
        for chunk in pending {
            let chunkStart = frame(chunk.startSecond)
            let chunkEnd = chunkStart + Int64(chunk.samples.count)
            let overlapStart = max(chunkStart, start)
            let overlapEnd = min(chunkEnd, end)
            guard overlapStart < overlapEnd else { continue }
            let sourceIndex = Int(overlapStart - chunkStart)
            let destIndex = Int(overlapStart - start)
            let frames = Int(overlapEnd - overlapStart)
            for offset in 0..<frames {
                let source = sourceIndex + offset
                let dest = destIndex + offset
                guard source >= 0, source < chunk.samples.count, dest >= 0, dest < count else { continue }
                if chunk.speaker == .system {
                    system[dest] += chunk.samples[source]
                } else {
                    microphone[dest] += chunk.samples[source]
                }
            }
        }
        var mixed = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let left = system[index]
            let right = microphone[index]
            let value: Float
            if abs(left) > 0.01, abs(right) > 0.01 {
                value = 0.5 * left + 0.5 * right
            } else {
                value = left + right
            }
            mixed[index] = min(1, max(-1, value))
        }
        write(mixed)
        committedFrames = end
        pending = pending.compactMap { chunk in
            let chunkStart = frame(chunk.startSecond)
            let chunkEnd = chunkStart + Int64(chunk.samples.count)
            if chunkEnd <= end { return nil }
            if chunkStart >= end { return chunk }
            let skip = Int(end - chunkStart)
            guard skip < chunk.samples.count else { return nil }
            let kept = Array(chunk.samples[skip...])
            let keptStart = sampleRate > 0 ? Double(end) / sampleRate : 0
            return MixChunk(speaker: chunk.speaker, startSecond: keptStart, samples: kept)
        }
    }

    private func write(_ samples: [Float]) {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = output.floatChannelData
        else { return }
        output.frameLength = AVAudioFrameCount(samples.count)
        for index in 0..<samples.count {
            destination[0][index] = samples[index]
        }
        do {
            try file?.write(from: output)
        } catch {
            if !loggedWriteError {
                loggedWriteError = true
                fputs("会話のwavの書き込みに失敗しました: \(error)\n", stderr)
            }
        }
    }

    private func frame(_ seconds: Double) -> Int64 {
        guard sampleRate > 0, seconds.isFinite else { return 0 }
        return Int64((seconds * sampleRate).rounded())
    }

    private static func finiteSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, !time.isIndefinite, !time.isNegativeInfinity, !time.isPositiveInfinity else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite else { return nil }
        return seconds
    }

    private static func positiveSeconds(_ time: CMTime) -> Double? {
        guard let seconds = finiteSeconds(time), seconds > 0 else { return nil }
        return seconds
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            return downmix(channels: channels, count: Int(buffer.format.channelCount), frames: frames)
        }
        guard let converted = convertToFloat(buffer), let channels = converted.floatChannelData else { return [] }
        return downmix(channels: channels, count: Int(converted.format.channelCount), frames: Int(converted.frameLength))
    }

    private static func downmix(channels: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int, frames: Int) -> [Float] {
        guard count > 0, frames > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frames)
        if count == 1 {
            samples.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                base.update(from: channels[0], count: frames)
            }
            return samples
        }
        let scale = 1 / Float(count)
        for index in 0..<frames {
            var sum: Float = 0
            for channel in 0..<count {
                sum += channels[channel][index]
            }
            samples[index] = sum * scale
        }
        return samples
    }

    private static func convertToFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = buffer.format.sampleRate > 0 ? format.sampleRate / buffer.format.sampleRate : 1
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

final class SessionStore: @unchecked Sendable {
    let directory: URL
    let transcriptURL: URL
    private let lock = NSLock()
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?
    private var conversation: ConversationMix?
    private var transcript: FileHandle?
    private let clock: DateFormatter
    private let header: String
    private var segments: [TranscriptSegment] = []
    private var loggedWriteError = false

    private init(directory: URL, transcriptURL: URL, transcript: FileHandle, header: String, format: AVAudioFormat) throws {
        self.directory = directory
        self.transcriptURL = transcriptURL
        self.transcript = transcript
        self.header = header
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        clock.timeZone = .current
        self.clock = clock
        systemFile = try Self.makeFile(directory.appendingPathComponent("audio-system.wav"), format: format)
        microphoneFile = try Self.makeFile(directory.appendingPathComponent("audio-mic.wav"), format: format)
        conversation = try ConversationMix(url: directory.appendingPathComponent("audio.wav"), sampleRate: format.sampleRate)
    }

    private static func makeFile(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    static func sessionsRoot(create: Bool) throws -> URL {
        let support = try SessionsRoot.supportDirectory(create: create)
        return try SessionsRoot.recordingRoot(in: support, create: create)
    }

    static func create(format: AVAudioFormat) throws -> SessionStore {
        let root = try sessionsRoot(create: true)
        let folderClock = DateFormatter()
        folderClock.locale = Locale(identifier: "en_US_POSIX")
        folderClock.dateFormat = "yyyyMMdd-HHmmss"
        folderClock.timeZone = .current
        let headingClock = DateFormatter()
        headingClock.locale = Locale(identifier: "en_US_POSIX")
        headingClock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        headingClock.timeZone = .current

        var directory = root.appendingPathComponent(folderClock.string(from: Date()), isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent(folderClock.string(from: Date()) + "-" + UUID().uuidString.prefix(4), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        let layout = format.channelCount == 1 ? "モノラル" : "\(format.channelCount)チャンネル"
        let header = "# \(headingClock.string(from: Date()))\n# \(Int(format.sampleRate)) Hz \(layout)\n"
        try header.data(using: .utf8)?.write(to: transcriptURL)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        return try SessionStore(directory: directory, transcriptURL: transcriptURL, transcript: handle, header: header, format: format)
    }

    func write(_ speaker: Speaker, buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let file = speaker == .system ? systemFile : microphoneFile
        do {
            try file?.write(from: buffer)
        } catch {
            if !loggedWriteError {
                loggedWriteError = true
                fputs("wavの書き込みに失敗しました: \(error)\n", stderr)
            }
        }
    }

    func mix(_ speaker: Speaker, buffer: AVAudioPCMBuffer?, at time: CMTime, duration: CMTime) {
        conversation?.add(speaker: speaker, buffer: buffer, at: time, duration: duration)
    }

    @discardableResult
    func append(speaker: Speaker, text: String, at date: Date, start: Double, end: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        segments.append(TranscriptSegment(speaker: speaker, wall: date, start: start, end: end, text: text))
        let line = Self.line(wall: date, label: speaker.label, text: text, clock: clock)
        if let data = (line + "\n").data(using: .utf8) {
            do {
                try transcript?.write(contentsOf: data)
            } catch {
                fputs("テキストの書き込みに失敗しました: \(error)\n", stderr)
            }
        }
        return line
    }

    func snapshot() -> [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }

    func replaceRemoteLabels(_ labels: [Int: String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let label = labels[index] ?? segment.speaker.label
            lines.append(Self.line(wall: segment.wall, label: label, text: segment.text, clock: clock))
        }
        let body = header + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? transcript?.close()
        transcript = nil
        do {
            try body.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("話者名の書き込みに失敗しました: \(error)\n", stderr)
        }
        return lines
    }

    private static func line(wall: Date, label: String, text: String, clock: DateFormatter) -> String {
        let stamp = "[\(clock.string(from: wall))]"
        if label == "自分" || label == "相手" {
            return "\(stamp) \(label) \(text)"
        }
        return "\(stamp) \(label)\t\(text)"
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? transcript?.synchronize()
        try? transcript?.close()
        transcript = nil
        systemFile = nil
        microphoneFile = nil
        conversation?.finish()
        conversation = nil
    }

    func discard() {
        close()
        try? FileManager.default.removeItem(at: directory)
    }

}

enum SessionsRootError: LocalizedError, Equatable {
    case unreadable
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "保存先の設定を読めないため、録音を始めていません"
        case .unavailable:
            return "保存先のフォルダを作れないため、録音を始めていません"
        }
    }
}

enum SessionsRoot {
    enum Preference: Equatable {
        case standard
        case custom(URL)
        case unreadable
    }

    struct Snapshot {
        var path: String
        var standard: Bool
        var unreadable: Bool
    }

    static func supportDirectory(create: Bool) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let root = base.appendingPathComponent("LocalTranscription", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func fileURL(in support: URL) -> URL {
        support.appendingPathComponent("sessions-root.txt")
    }

    static func defaultDirectory(in support: URL) -> URL {
        support.appendingPathComponent("sessions", isDirectory: true)
    }

    static func load(in support: URL) -> Preference {
        let url = fileURL(in: support)
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .standard }
        guard trimmed.hasPrefix("/") else { return .unreadable }
        return .custom(URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL)
    }

    static func snapshot(in support: URL) -> Snapshot {
        switch load(in: support) {
        case .standard:
            return Snapshot(path: defaultDirectory(in: support).path, standard: true, unreadable: false)
        case .custom(let url):
            return Snapshot(path: url.path, standard: false, unreadable: false)
        case .unreadable:
            return Snapshot(path: fileURL(in: support).path, standard: false, unreadable: true)
        }
    }

    static func listingRoots(in support: URL) -> [URL] {
        var roots: [URL] = []
        func append(_ url: URL) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !roots.contains(where: { same($0, resolved) }) else {
                return
            }
            roots.append(resolved)
        }
        append(defaultDirectory(in: support))
        if case .custom(let url) = load(in: support) {
            append(url)
        }
        return roots
    }

    static func recordingRoot(in support: URL, create: Bool) throws -> URL {
        switch load(in: support) {
        case .unreadable:
            throw SessionsRootError.unreadable
        case .standard:
            let root = defaultDirectory(in: support)
            if create {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            return root
        case .custom(let url):
            try prepare(url, create: create)
            return url
        }
    }

    static func use(_ folder: URL, in support: URL) throws {
        let folder = folder.standardizedFileURL
        if same(folder, defaultDirectory(in: support)) {
            try clear(in: support)
            return
        }
        try prepare(folder, create: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try save(folder, in: support)
    }

    static func clear(in support: URL) throws {
        let url = fileURL(in: support)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else { throw SessionsRootError.unreadable }
        try FileManager.default.removeItem(at: url)
    }

    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func prepare(_ url: URL, create: Bool) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, FileManager.default.isWritableFile(atPath: url.path) else {
                throw SessionsRootError.unavailable
            }
            return
        }
        guard create else { throw SessionsRootError.unavailable }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SessionsRootError.unavailable
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw SessionsRootError.unavailable
        }
    }

    private static func save(_ folder: URL, in support: URL) throws {
        let text = folder.standardizedFileURL.path + "\n"
        try text.write(to: fileURL(in: support), atomically: true, encoding: .utf8)
    }
}

struct Recording {
    var directory: URL
    var stamp: String
    var when: String
    var title: String
    var excerpt: String
}

enum SessionCatalogError: Error {
    case unrecognizedFolder
}

enum SessionCatalog {
    static func sanitize(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.value < 0x20 || scalar == "/" || scalar == ":" || scalar == "\\" {
                return " "
            }
            return scalar
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard trimmed.count > 60 else { return trimmed }
        return String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static func recordings() -> [Recording] {
        guard let support = try? SessionsRoot.supportDirectory(create: false) else { return [] }
        return recordings(in: SessionsRoot.listingRoots(in: support))
    }

    static func recordings(in roots: [URL]) -> [Recording] {
        var seen = Set<String>()
        var all: [Recording] = []
        for root in roots {
            for recording in recordings(in: root) {
                let key = recording.directory.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(key).inserted else { continue }
                all.append(recording)
            }
        }
        return all.sorted { $0.stamp > $1.stamp }
    }

    static func recordings(in root: URL) -> [Recording] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap(load).sorted { $0.stamp > $1.stamp }
    }

    static func title(in directory: URL) -> String {
        headerTitle(in: readTranscript(directory))
    }

    @discardableResult
    static func apply(title raw: String, to directory: URL) throws -> URL {
        let title = sanitize(raw)
        let destination = try renamedDirectory(directory, title: title)
        let transcript = destination.appendingPathComponent("transcript.txt")
        let original = try String(contentsOf: transcript, encoding: .utf8)
        let updated = replacingTitle(in: original, with: title)
        if updated != original {
            try updated.write(to: transcript, atomically: true, encoding: .utf8)
        }
        return destination
    }

    private static func load(_ directory: URL) -> Recording? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let split = splitFolderName(directory.lastPathComponent) else {
            return nil
        }
        let transcript = readTranscript(directory)
        let header = headerTitle(in: transcript)
        return Recording(
            directory: directory,
            stamp: split.stamp,
            when: displayWhen(split.stamp),
            title: header.isEmpty ? split.title : header,
            excerpt: firstOpponent(in: transcript)
        )
    }

    private static func renamedDirectory(_ directory: URL, title: String) throws -> URL {
        guard let split = splitFolderName(directory.lastPathComponent) else {
            throw SessionCatalogError.unrecognizedFolder
        }
        let nextName = title.isEmpty ? split.stamp : "\(split.stamp) \(title)"
        if nextName == directory.lastPathComponent {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        var destination = parent.appendingPathComponent(nextName, isDirectory: true)
        var extra = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(nextName) \(extra)", isDirectory: true)
            extra += 1
            if extra > 20 {
                throw SessionCatalogError.unrecognizedFolder
            }
        }
        try FileManager.default.moveItem(at: directory, to: destination)
        return destination
    }

    static func splitFolderName(_ name: String) -> (stamp: String, title: String)? {
        let pattern = #"^(\d{8}-\d{6}(?:-[0-9A-Fa-f]{4})?)(?: (.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let stampRange = Range(match.range(at: 1), in: name) else {
            return nil
        }
        let title: String
        if match.range(at: 2).location != NSNotFound, let titleRange = Range(match.range(at: 2), in: name) {
            title = String(name[titleRange])
        } else {
            title = ""
        }
        return (String(name[stampRange]), title)
    }

    private static func displayWhen(_ stamp: String) -> String {
        let parts = stamp.split(separator: "-")
        guard let day = parts.first, day.count == 8, parts.count >= 2, parts[1].count >= 4 else {
            return stamp
        }
        let time = parts[1]
        let year = day.prefix(4)
        let month = day.dropFirst(4).prefix(2)
        let date = day.dropFirst(6).prefix(2)
        let hour = time.prefix(2)
        let minute = time.dropFirst(2).prefix(2)
        return "\(year)-\(month)-\(date) \(hour):\(minute)"
    }

    private static func readTranscript(_ directory: URL) -> String {
        let url = directory.appendingPathComponent("transcript.txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func headerTitle(in text: String) -> String {
        for line in normalizedLines(text) {
            if line.hasPrefix("# 題 ") {
                return String(line.dropFirst("# 題 ".count))
            }
            if !line.hasPrefix("#") {
                break
            }
        }
        return ""
    }

    private static func replacingTitle(in text: String, with title: String) -> String {
        var lines = normalizedLines(text)
        if lines.first?.hasPrefix("# 題 ") == true {
            if title.isEmpty {
                lines.removeFirst()
            } else {
                lines[0] = "# 題 \(title)"
            }
        } else if !title.isEmpty {
            lines.insert("# 題 \(title)", at: 0)
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func firstOpponent(in text: String) -> String {
        for line in normalizedLines(text) {
            guard let parsed = TranscriptLine(line), parsed.label != "自分", !parsed.text.isEmpty else { continue }
            return parsed.text
        }
        return ""
    }

    private static func normalizedLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
