/// 停止後に名前を聞くかどうか。macOS は他アプリが前面のあいだ、こちらの前面化を保証しない。
struct TitlePrompt {
    var appActive: Bool
    var recording: Bool
    var preparing: Bool
    var resetting: Bool
    var askingReset: Bool

    var asksNow: Bool {
        appActive && !recording && !preparing && !resetting && !askingReset
    }
}

struct TitlePromptQueue {
    private(set) var paths: [String] = []

    mutating func add(_ path: String) {
        paths.append(path)
    }

    mutating func next(when prompt: TitlePrompt) -> String? {
        guard prompt.asksNow, !paths.isEmpty else { return nil }
        return paths.removeFirst()
    }
}
