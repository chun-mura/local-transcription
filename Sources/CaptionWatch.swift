import ApplicationServices
import AppKit
import Foundation

struct SpeakerLog: Equatable {
    var marks: [SpeakerMark]
    var localNames: Set<String>
}

final class CaptionWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local-transcription.captions")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var polling = false
    private var marks: [SpeakerMark] = []
    private var localNames: Set<String> = ["あなた"]
    private var lastSpeaker: String?
    private var now: @Sendable () -> Double = { 0 }

    func start(now: @escaping @Sendable () -> Double) {
        lock.lock()
        self.now = now
        marks = []
        localNames = ["あなた"]
        lastSpeaker = nil
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> SpeakerLog {
        timer?.cancel()
        timer = nil
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return SpeakerLog(marks: marks, localNames: localNames)
    }

    private func poll() {
        lock.lock()
        let busy = polling
        if !busy { polling = true }
        let clock = now
        lock.unlock()
        guard !busy else { return }
        defer {
            lock.lock()
            polling = false
            lock.unlock()
        }
        guard AXIsProcessTrusted() else { return }
        let sample = CaptionRead.sample(in: windows())
        let time = clock()
        lock.lock()
        if let local = sample.localName, !local.isEmpty {
            localNames.insert(local)
        }
        let speaker = sample.speaker ?? ""
        if speaker != (lastSpeaker ?? "") {
            lastSpeaker = speaker
            marks.append(SpeakerMark(time: time, name: speaker))
        }
        lock.unlock()
    }

    private func windows() -> [CaptionNode] {
        var nodes: [CaptionNode] = []
        for bundle in ["com.google.Chrome", "com.microsoft.teams2"] {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
                continue
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for window in elements(axApp, kAXWindowsAttribute) {
                let title = stringAttr(window, kAXTitleAttribute)
                let document = stringAttr(window, "AXDocument")
                guard shouldWalk(title: title, document: document) else { continue }
                var count = 0
                nodes.append(node(window, depth: 0, count: &count))
            }
        }
        return nodes
    }

    private func shouldWalk(title: String, document: String) -> Bool {
        if title.contains("Meet") || document.contains("meet.google.com") { return true }
        if title.contains("会議") { return true }
        return false
    }

    private func node(_ element: AXUIElement, depth: Int, count: inout Int) -> CaptionNode {
        count += 1
        let role = stringAttr(element, kAXRoleAttribute)
        var children: [CaptionNode] = []
        if depth < 30, count < 8_000 {
            for child in elements(element, kAXChildrenAttribute) {
                children.append(node(child, depth: depth + 1, count: &count))
            }
        }
        return CaptionNode(
            role: role,
            title: stringAttr(element, kAXTitleAttribute),
            value: stringAttr(element, kAXValueAttribute),
            classes: stringAttr(element, "AXDOMClassList"),
            children: children
        )
    }

    private func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return [] }
        if let list = value as? [AXUIElement] { return list }
        guard let list = value as? NSArray else { return [] }
        return (0..<list.count).map { unsafeBitCast(list[$0], to: AXUIElement.self) }
    }

    private func stringAttr(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        switch value {
        case let text as String:
            return text
        case let list as [String]:
            return list.joined(separator: " ")
        case let list as NSArray:
            return list.compactMap { $0 as? String }.joined(separator: " ")
        default:
            return ""
        }
    }
}
