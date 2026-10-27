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

final class SessionStore: @unchecked Sendable {
    let directory: URL
    let transcriptURL: URL
    private let lock = NSLock()
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?
    private var transcript: FileHandle?
    private let clock: DateFormatter
    private var loggedWriteError = false

    private init(directory: URL, transcriptURL: URL, transcript: FileHandle, format: AVAudioFormat) throws {
        self.directory = directory
        self.transcriptURL = transcriptURL
        self.transcript = transcript
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
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let root = base.appendingPathComponent("LocalTranscription/sessions", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
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
        return try SessionStore(directory: directory, transcriptURL: transcriptURL, transcript: handle, format: format)
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
    func append(speaker: Speaker, text: String, at date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(clock.string(from: date))] \(speaker.label) \(text)"
        if let data = (line + "\n").data(using: .utf8) {
            do {
                try transcript?.write(contentsOf: data)
            } catch {
                fputs("テキストの書き込みに失敗しました: \(error)\n", stderr)
            }
        }
        return line
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
        guard let root = try? SessionStore.sessionsRoot(create: false),
              FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return recordings(in: root)
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
            guard let range = line.range(of: "] 相手 ") else { continue }
            return String(line[range.upperBound...])
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
