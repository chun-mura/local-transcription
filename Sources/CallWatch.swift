import Foundation

enum CallKind: Equatable {
    case teams
    case meet
}

enum CallWatchEffect: Equatable {
    case showPrompt(CallKind)
    case dismissPrompt
    case startRecording
    case stopRecording
}

struct CallWatchSettings: Equatable {
    var autoStart: Bool
    var autoStop: Bool

    static let off = CallWatchSettings(autoStart: false, autoStop: false)

    static func fileURL(in support: URL) -> URL {
        support.appendingPathComponent("call-watch.txt")
    }

    static func load(from url: URL) -> CallWatchSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .off }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .off }
        var autoStart = false
        var autoStop = false
        var sawKnown = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return .off }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "0" || value == "1" else { return .off }
            switch key {
            case "auto-start":
                autoStart = value == "1"
                sawKnown = true
            case "auto-stop":
                autoStop = value == "1"
                sawKnown = true
            default:
                return .off
            }
        }
        guard sawKnown else { return .off }
        if !autoStart { autoStop = false }
        return CallWatchSettings(autoStart: autoStart, autoStop: autoStop)
    }

    func save(to url: URL) throws {
        let text = "auto-start=\(autoStart ? "1" : "0")\nauto-stop=\(autoStop ? "1" : "0")\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func settingAutoStart(_ on: Bool) -> CallWatchSettings {
        CallWatchSettings(autoStart: on, autoStop: on && autoStop)
    }

    func settingAutoStop(_ on: Bool) -> CallWatchSettings {
        guard autoStart else { return CallWatchSettings(autoStart: false, autoStop: false) }
        return CallWatchSettings(autoStart: true, autoStop: on)
    }
}

enum CallApps {
    static func isTeams(_ bundleID: String) -> Bool {
        if bundleID.localizedCaseInsensitiveContains("notificationcenter") { return false }
        if isFamily(bundleID, root: "com.microsoft.teams2") { return isCallHelper(bundleID, root: "com.microsoft.teams2") }
        if isFamily(bundleID, root: "com.microsoft.teams") { return isCallHelper(bundleID, root: "com.microsoft.teams") }
        return false
    }

    static func isMeetBrowser(_ bundleID: String) -> Bool {
        for root in ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser"] {
            if isFamily(bundleID, root: root) { return true }
        }
        return false
    }

    static func isWebKitAudio(_ bundleID: String) -> Bool {
        bundleID == "com.apple.WebKit.GPU" || bundleID == "com.apple.WebKit.WebContent"
    }

    private static func isFamily(_ bundleID: String, root: String) -> Bool {
        bundleID == root || bundleID.hasPrefix(root + ".")
    }

    private static func isCallHelper(_ bundleID: String, root: String) -> Bool {
        if bundleID == root { return true }
        let rest = bundleID.dropFirst(root.count + 1)
        return rest.contains("helper") || rest.contains("modulehost")
    }
}

enum MeetWindow {
    static func isLiveCall(title: String) -> Bool {
        if title.contains("Meet –") || title.contains("Meet -") { return true }
        return containsMeetingCode(title)
    }

    static func isLiveCall(document: String) -> Bool {
        guard let url = URL(string: document), let host = url.host?.lowercased() else { return false }
        guard host == "meet.google.com" || host.hasSuffix(".meet.google.com") else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "landing" || path == "new" || path == "_meet" { return false }
        return containsMeetingCode(path)
    }

    private static func containsMeetingCode(_ text: String) -> Bool {
        let chars = Array(text.lowercased())
        let width = 12
        guard chars.count >= width else { return false }
        for index in 0...(chars.count - width) {
            guard boundaryBefore(chars, index),
                  letters(chars, from: index, count: 3),
                  chars[index + 3] == "-",
                  letters(chars, from: index + 4, count: 4),
                  chars[index + 8] == "-",
                  letters(chars, from: index + 9, count: 3),
                  boundaryAfter(chars, index + width) else { continue }
            return true
        }
        return false
    }

    private static func letters(_ chars: [Character], from index: Int, count: Int) -> Bool {
        for offset in 0..<count {
            guard isLetter(chars[index + offset]) else { return false }
        }
        return true
    }

    private static func boundaryBefore(_ chars: [Character], _ index: Int) -> Bool {
        if index <= 0 { return true }
        return !isCodeCharacter(chars[index - 1])
    }

    private static func boundaryAfter(_ chars: [Character], _ index: Int) -> Bool {
        if index >= chars.count { return true }
        return !isCodeCharacter(chars[index])
    }

    private static func isLetter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return value >= 97 && value <= 122
    }

    private static func isCodeCharacter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        let digit = value >= 48 && value <= 57
        return digit || isLetter(character)
    }
}

struct CallWatchInput: Equatable {
    var now: Date
    var teams: Bool
    var meet: Bool
    var recording: Bool
    var preparing: Bool
    var naming: Bool
    var resetting: Bool
    var autoStarted: Bool
    var settings: CallWatchSettings
}

struct CallWatch {
    static let hold: TimeInterval = 4
    static let release: TimeInterval = 30

    private enum Phase: Equatable {
        case idle
        case holding(since: Date, kind: CallKind)
        case active(kind: CallKind, offered: Bool, prompt: Bool)
        case ending(since: Date, kind: CallKind, offered: Bool, prompt: Bool)
    }

    private var phase: Phase = .idle

    mutating func tick(_ input: CallWatchInput) -> [CallWatchEffect] {
        switch phase {
        case .idle:
            if let kind = liveKind(previous: nil, teams: input.teams, meet: input.meet) {
                phase = .holding(since: input.now, kind: kind)
            }
            return []
        case .holding(let since, let kind):
            guard let current = liveKind(previous: kind, teams: input.teams, meet: input.meet) else {
                phase = .idle
                return []
            }
            guard input.now.timeIntervalSince(since) >= Self.hold else {
                phase = .holding(since: since, kind: current)
                return []
            }
            return begin(kind: current, input: input)
        case .active(let kind, let offered, var prompt):
            guard let current = liveKind(previous: kind, teams: input.teams, meet: input.meet) else {
                phase = .ending(since: input.now, kind: kind, offered: offered, prompt: prompt)
                return []
            }
            var effects: [CallWatchEffect] = []
            if prompt, input.recording {
                prompt = false
                effects.append(.dismissPrompt)
            }
            phase = .active(kind: current, offered: offered, prompt: prompt)
            return effects
        case .ending(let since, let kind, let offered, var prompt):
            if let current = liveKind(previous: kind, teams: input.teams, meet: input.meet) {
                var effects: [CallWatchEffect] = []
                if prompt, input.recording {
                    prompt = false
                    effects.append(.dismissPrompt)
                }
                phase = .active(kind: current, offered: offered, prompt: prompt)
                return effects
            }
            guard input.now.timeIntervalSince(since) >= Self.release else { return [] }
            return finish(prompt: prompt, input: input)
        }
    }

    mutating func decline() {
        clearPrompt()
    }

    mutating func notePromptClosed() {
        clearPrompt()
    }

    private mutating func begin(kind: CallKind, input: CallWatchInput) -> [CallWatchEffect] {
        if input.recording {
            phase = .active(kind: kind, offered: true, prompt: false)
            return []
        }
        let blocked = input.preparing || input.naming || input.resetting
        if input.settings.autoStart {
            phase = .active(kind: kind, offered: true, prompt: false)
            if blocked { return [] }
            return [.startRecording]
        }
        phase = .active(kind: kind, offered: true, prompt: true)
        return [.showPrompt(kind)]
    }

    private mutating func finish(prompt: Bool, input: CallWatchInput) -> [CallWatchEffect] {
        phase = .idle
        var effects: [CallWatchEffect] = []
        if prompt { effects.append(.dismissPrompt) }
        if input.settings.autoStop, input.autoStarted, input.recording {
            effects.append(.stopRecording)
        }
        return effects
    }

    private mutating func clearPrompt() {
        switch phase {
        case .active(let kind, let offered, _):
            phase = .active(kind: kind, offered: offered, prompt: false)
        case .ending(let since, let kind, let offered, _):
            phase = .ending(since: since, kind: kind, offered: offered, prompt: false)
        default:
            break
        }
    }

    private func liveKind(previous: CallKind?, teams: Bool, meet: Bool) -> CallKind? {
        if let previous {
            switch previous {
            case .teams where teams:
                return .teams
            case .meet where meet:
                return .meet
            default:
                break
            }
        }
        if teams { return .teams }
        if meet { return .meet }
        return nil
    }
}
