import Foundation

@main
enum SessionTest {
    static func main() throws {
        checkSanitize()
        try checkApply()
        try checkOrder()
    }
}

private func checkSanitize() {
    expect(SessionCatalog.sanitize("  企画 / 定例  "), "企画 定例")
    expect(SessionCatalog.sanitize("a:b\\c"), "a b c")
    expect(SessionCatalog.sanitize("   "), "")
    expect(SessionCatalog.sanitize(String(repeating: "あ", count: 80)).count, 60)
}

private func checkApply() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let folder = root.appendingPathComponent("20261027-153104", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let body = """
    # 2026-10-27 15:31:04
    # 16000 Hz モノラル
    [15:31:10] 自分 はい
    [15:31:12] 相手 今週の定例です

    """
    let transcript = folder.appendingPathComponent("transcript.txt")
    try body.write(to: transcript, atomically: true, encoding: .utf8)

    let named = try SessionCatalog.apply(title: "企画/定例", to: folder)
    expect(named.lastPathComponent, "20261027-153104 企画 定例")
    let namedText = try String(contentsOf: named.appendingPathComponent("transcript.txt"), encoding: .utf8)
    expect(namedText.hasPrefix("# 題 企画 定例\n# 2026-10-27 15:31:04\n"), true)
    expect(namedText.contains("[15:31:10] 自分 はい\n"), true)
    expect(SessionCatalog.recordings(in: root).first?.excerpt, "今週の定例です")
    expect(SessionCatalog.recordings(in: root).first?.when, "2026-10-27 15:31")

    let renamed = try SessionCatalog.apply(title: "振り返り", to: named)
    let replaced = try String(contentsOf: renamed.appendingPathComponent("transcript.txt"), encoding: .utf8)
    expect(replaced.hasPrefix("# 題 振り返り\n"), true)
    expect(replaced.contains("# 題 企画"), false)

    let cleared = try SessionCatalog.apply(title: "  ", to: renamed)
    expect(cleared.lastPathComponent, "20261027-153104")
    let clearedText = try String(contentsOf: cleared.appendingPathComponent("transcript.txt"), encoding: .utf8)
    expect(clearedText.hasPrefix("# 2026-10-27 15:31:04\n"), true)
}

private func checkOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["20261027-120000", "20261027-180000-ab12", "20261026-090000 古い"] {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# 2026-10-27 12:00:00\n".write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }
    let stamps = SessionCatalog.recordings(in: root).map(\.stamp)
    expect(stamps, ["20261027-180000-ab12", "20261027-120000", "20261026-090000"])
    expect(SessionCatalog.recordings(in: root).last?.title, "古い")
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}
