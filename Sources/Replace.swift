enum FinalReplacements {
    private static let pairs = [
        ("ノーション", "Notion"),
    ]

    static func apply(_ text: String) -> String {
        pairs.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }
}
