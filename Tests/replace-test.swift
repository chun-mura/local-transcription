import Foundation

@main
enum ReplaceTest {
    static func main() {
        let notion = [FrequentWord(word: "Notion", similars: ["ノーション"])]
        check("ノーションで書いてるやつ", "Notionで書いてるやつ", notion)
        check("この設定はそのまま", "この設定はそのまま", notion)
        check("各種の設定とフリーとデビュー", "各種の設定とフリーとデビュー", notion)
        check("ノーションとノーション", "NotionとNotion", notion)
        check("ノーション", "Notion", [
            FrequentWord(word: "Notion", similars: ["ノーション"]),
            FrequentWord(word: "メモ", similars: ["Notion"])
        ])

        check("定例会議です", "週次です", [
            FrequentWord(word: "ミーティング", similars: ["会議"]),
            FrequentWord(word: "週次", similars: ["定例会議"])
        ])
        check("会議", "先", [
            FrequentWord(word: "先", similars: ["会議"]),
            FrequentWord(word: "後", similars: ["会議"])
        ])
        check("そのまま", "そのまま", [FrequentWord(word: "言葉", similars: ["", "  "])])

        expect(FrequentWords.parseSimilars("ノーション、ノーシオン"), ["ノーション", "ノーシオン"])
        expect(FrequentWords.parseSimilars("ノーション,ノーシオン"), ["ノーション", "ノーシオン"])
        expect(FrequentWords.parseSimilars("ノーション，ノーシオン"), ["ノーション", "ノーシオン"])
        expect(FrequentWords.parseSimilars("ノーション\nノーシオン"), ["ノーション", "ノーシオン"])
        expect(FrequentWords.parseSimilars("Google Meet"), ["Google Meet"])
        expect(FrequentWords.parseSimilars(" ノーション 、 ノーション "), ["ノーション"])

        expect(FrequentWords.storedForm([
            FrequentWord(word: "  ", similars: ["残る"]),
            FrequentWord(word: " Notion ", similars: [" ノーション ", "ノーション", ""])
        ]), [FrequentWord(word: "Notion", similars: ["ノーション"])])

        checkFiles()
    }
}

private func check(_ input: String, _ expected: String, _ words: [FrequentWord]) {
    expect(FrequentWords.convert(input, words: words), expected)
}

private func checkFiles() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("frequent-words-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let missing = root.appendingPathComponent("missing", isDirectory: true)
    guard case .words(let seeded) = FrequentWordsFile.load(in: missing) else {
        fail("初回の設定を書けませんでした")
    }
    expect(seeded, FrequentWords.seeded)
    guard case .words(let again) = FrequentWordsFile.load(in: missing) else {
        fail("書いた設定を読めませんでした")
    }
    expect(again, FrequentWords.seeded)

    let customDirectory = root.appendingPathComponent("custom", isDirectory: true)
    let custom = [FrequentWord(word: "週次", similars: ["しゅうじ"])]
    do {
        try FrequentWordsFile.save(custom, to: customDirectory)
        let url = FrequentWordsFile.fileURL(in: customDirectory)
        let before = try Data(contentsOf: url)
        guard case .words(let loaded) = FrequentWordsFile.load(in: customDirectory) else {
            fail("ある設定を読めませんでした")
        }
        expect(loaded, custom)
        expect(try Data(contentsOf: url), before)
    } catch {
        fail("設定の読み書きに失敗しました: \(error)")
    }

    let brokenDirectory = root.appendingPathComponent("broken", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let url = FrequentWordsFile.fileURL(in: brokenDirectory)
        let broken = Data("not-json".utf8)
        try broken.write(to: url)
        guard case .unreadable = FrequentWordsFile.load(in: brokenDirectory) else {
            fail("壊れた設定を受け入れました")
        }
        expect(try Data(contentsOf: url), broken)
    } catch {
        fail("壊れた設定の確認に失敗しました: \(error)")
    }
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}

private func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
