import Foundation

struct CaptionNode: Equatable {
    var role: String = ""
    var title: String = ""
    var value: String = ""
    var classes: String = ""
    var children: [CaptionNode] = []
}

struct CaptionSample: Equatable {
    var speaker: String?
    var localName: String?
}

struct SpeakerMark: Equatable {
    var time: Double
    var name: String
}

enum CaptionRead {
    static func sample(in windows: [CaptionNode]) -> CaptionSample {
        var speaker: String?
        var localName: String?
        for window in windows {
            if let name = meetSpeaker(in: window) {
                speaker = name
                localName = "あなた"
            }
            if let name = teamsSpeaker(in: window) {
                speaker = name
            }
            if let name = teamsLocalName(in: window) {
                localName = name
            }
        }
        return CaptionSample(speaker: speaker, localName: localName)
    }

    static func meetSpeaker(in node: CaptionNode) -> String? {
        var last: String?
        func walk(_ node: CaptionNode) {
            if classList(node.classes).contains("KcIKyf"), let name = firstStaticText(node) {
                last = bounded(name)
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(node)
        return last
    }

    static func teamsSpeaker(in node: CaptionNode) -> String? {
        guard let caption = find(node, where: { $0.title == "ライブ キャプション" }) else { return nil }
        var last: String?
        func walk(_ node: CaptionNode) {
            let texts = node.children.compactMap { child -> String? in
                guard child.role == "AXStaticText" else { return nil }
                let text = child.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            if texts.count >= 2 {
                let index = texts.count.isMultiple(of: 2) ? texts.count - 2 : texts.count - 1
                if let name = bounded(texts[index]) {
                    last = name
                }
            } else if texts.count == 1, let name = bounded(texts[0]) {
                let nested = node.children.contains { child in
                    child.role != "AXStaticText" && (child.title == "未確認" || containsStaticText(child))
                }
                if nested {
                    last = name
                }
            }
            for child in node.children where child.role != "AXStaticText" {
                walk(child)
            }
        }
        walk(caption)
        return last
    }

    static func teamsLocalName(in node: CaptionNode) -> String? {
        let marker = "自分のビデオ, "
        var found: String?
        func walk(_ node: CaptionNode) {
            let blob = node.title.isEmpty ? node.value : node.title
            if let range = blob.range(of: marker) {
                let rest = blob[range.upperBound...]
                let name = rest.split(separator: ",", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                if let name = bounded(name) {
                    found = name
                }
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(node)
        return found
    }

    private static func find(_ node: CaptionNode, where match: (CaptionNode) -> Bool) -> CaptionNode? {
        if match(node) { return node }
        for child in node.children {
            if let found = find(child, where: match) { return found }
        }
        return nil
    }

    private static func firstStaticText(_ node: CaptionNode) -> String? {
        if node.role == "AXStaticText" {
            let text = node.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        for child in node.children {
            if let text = firstStaticText(child) { return text }
        }
        return nil
    }

    private static func containsStaticText(_ node: CaptionNode) -> Bool {
        if node.role == "AXStaticText" {
            return !node.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return node.children.contains(where: containsStaticText)
    }

    private static func classList(_ classes: String) -> Set<String> {
        Set(classes.split(separator: " ").map(String.init))
    }

    private static func bounded(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 40 else { return nil }
        return cleaned
    }
}

enum SpeakerAssign {
    static func remoteLabel(
        start: Double,
        end: Double,
        marks: [SpeakerMark],
        localNames: Set<String>,
        until: Double
    ) -> String? {
        let duration = end - start
        guard duration > 0 else { return nil }
        var local = localNames
        local.insert("あなた")
        var bestName: String?
        var best = 0.0
        for span in spans(marks: marks, until: max(until, end)) {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > best else { continue }
            best = overlap
            bestName = span.name
        }
        guard best >= duration * 0.5, let bestName, !local.contains(bestName) else { return nil }
        return bestName
    }

    private static func spans(marks: [SpeakerMark], until: Double) -> [(start: Double, end: Double, name: String)] {
        var result: [(Double, Double, String)] = []
        for (index, mark) in marks.enumerated() {
            let end = index + 1 < marks.count ? marks[index + 1].time : until
            guard end > mark.time, !mark.name.isEmpty else { continue }
            result.append((mark.time, end, mark.name))
        }
        return result
    }
}
