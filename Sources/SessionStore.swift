import AVFoundation
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

final class SessionStore: @unchecked Sendable {
    let directory: URL
    let transcriptURL: URL
    private let lock = NSLock()
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?
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
