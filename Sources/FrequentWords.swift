import Foundation

struct FrequentWord: Equatable, Decodable {
    var word: String
    var similars: [String]
}

enum FrequentWordsLoad {
    case words([FrequentWord])
    case unreadable(URL)
}

enum FrequentWords {
    static let seeded = [FrequentWord(word: "Notion", similars: ["ノーション"])]

    static func convert(_ text: String, words: [FrequentWord]) -> String {
        struct Span {
            var range: Range<String.Index>
            var word: String
            var length: Int
            var order: Int
        }

        var spans: [Span] = []
        for (order, entry) in words.enumerated() {
            let canonical = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            for similar in entry.similars {
                let needle = similar.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { continue }
                var search = text.startIndex
                while search < text.endIndex, let found = text.range(of: needle, range: search..<text.endIndex) {
                    spans.append(Span(range: found, word: canonical, length: needle.count, order: order))
                    search = found.upperBound
                }
            }
        }

        spans.sort { lhs, rhs in
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        var chosen: [Span] = []
        for span in spans {
            let hit = chosen.contains { existing in
                existing.range.overlaps(span.range)
            }
            if !hit { chosen.append(span) }
        }
        chosen.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result = ""
        var cursor = text.startIndex
        for span in chosen {
            result += text[cursor..<span.range.lowerBound]
            result += span.word
            cursor = span.range.upperBound
        }
        result += text[cursor..<text.endIndex]
        return result
    }

    static func parseSimilars(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in raw {
            if character == "、" || character == "," || character == "，" || character == "\n" || character == "\r" {
                appendSimilar(&tokens, current)
                current = ""
            } else {
                current.append(character)
            }
        }
        appendSimilar(&tokens, current)
        return tokens
    }

    static func formatSimilars(_ similars: [String]) -> String {
        similars.joined(separator: "、")
    }

    static func storedForm(_ words: [FrequentWord]) -> [FrequentWord] {
        words.compactMap { entry in
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return FrequentWord(word: word, similars: parseSimilars(formatSimilars(entry.similars)))
        }
    }

    private static func appendSimilar(_ tokens: inout [String], _ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tokens.contains(trimmed) else { return }
        tokens.append(trimmed)
    }
}

enum FrequentWordsFile {
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

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("frequent-words.json")
    }

    static func load(in directory: URL) -> FrequentWordsLoad {
        let url = fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            do {
                try save(FrequentWords.seeded, to: directory)
                return .words(FrequentWords.seeded)
            } catch {
                return .unreadable(url)
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)
            return .words(document.words)
        } catch {
            return .unreadable(url)
        }
    }

    static func save(_ words: [FrequentWord], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "words": words.map { entry in
                ["similars": entry.similars, "word": entry.word]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL(in: directory), options: .atomic)
    }

    private struct Document: Decodable {
        var words: [FrequentWord]
    }
}

final class FrequentWordsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL?
    private var words: [FrequentWord] = []
    private var unreadable = false

    init() {
        do {
            directory = try FrequentWordsFile.supportDirectory(create: true)
        } catch {
            directory = nil
            unreadable = true
            fputs("頻出ワードの保存先を作れません: \(error)\n", stderr)
            return
        }
        guard let directory else { return }
        switch FrequentWordsFile.load(in: directory) {
        case .words(let loaded):
            words = loaded
        case .unreadable(let url):
            unreadable = true
            fputs("頻出ワードの設定を読めないため、変換しません: \(url.path)\n", stderr)
        }
    }

    func apply(_ text: String) -> String {
        lock.lock()
        let words = words
        lock.unlock()
        return FrequentWords.convert(text, words: words)
    }

    func current() -> (words: [FrequentWord], unreadable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (words, unreadable)
    }

    func update(_ words: [FrequentWord]) -> Bool {
        lock.lock()
        let blocked = unreadable
        let directory = directory
        lock.unlock()
        guard !blocked, let directory else { return false }
        do {
            try FrequentWordsFile.save(words, to: directory)
        } catch {
            fputs("頻出ワードを保存できません: \(error)\n", stderr)
            return false
        }
        lock.lock()
        self.words = words
        lock.unlock()
        return true
    }
}
