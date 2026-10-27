import Foundation

@main
enum ReplaceTest {
    static func main() {
        check("ノーションで書いてるやつ", "Notionで書いてるやつ")
        check("この設定はそのまま", "この設定はそのまま")
        check("各種の設定とフリーとデビュー", "各種の設定とフリーとデビュー")
    }
}

private func check(_ input: String, _ expected: String) {
    let actual = FinalReplacements.apply(input)
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}
