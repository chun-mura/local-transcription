import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

struct CallObservation: Equatable, Sendable {
    var teams: Bool
    var meet: Bool
    var detail: String

    static let none = CallObservation(teams: false, meet: false, detail: "")
}

final class CallDetect: @unchecked Sendable {
    var onObservation: (@Sendable (CallObservation) -> Void)?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(label: "local-transcription.call-detect")
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let observation = Self.observe()
            let deliver = self.onObservation
            DispatchQueue.main.async {
                deliver?(observation)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    static func observe() -> CallObservation {
        let inputs = runningInputs()
        let teams = inputs.contains { CallApps.isTeams($0.bundleID) }
        let safariRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Safari"
        }
        let browserMic = inputs.contains { input in
            CallApps.isMeetBrowser(input.bundleID) || (safariRunning && CallApps.isWebKitAudio(input.bundleID))
        }
        var titles: [String] = []
        var documents: [String] = []
        var looked = false
        if browserMic, CGPreflightScreenCaptureAccess() {
            looked = true
            let windows = browserWindows()
            titles = windows.map(\.title).filter { !$0.isEmpty }
            documents = windows.map(\.document).filter { !$0.isEmpty }
        }
        let meet = browserMic && looked && (
            titles.contains { MeetWindow.isLiveCall(title: $0) }
                || documents.contains { MeetWindow.isLiveCall(document: $0) }
        )
        return CallObservation(
            teams: teams,
            meet: meet,
            detail: detail(inputs: inputs, titles: titles, documents: documents, looked: looked)
        )
    }

    private struct InputProcess {
        var bundleID: String
    }

    private struct BrowserWindow {
        var title: String
        var document: String
    }

    private static func runningInputs() -> [InputProcess] {
        processIDs().compactMap { objectID in
            guard isRunningInput(objectID), let bundleID = bundleID(of: objectID), !bundleID.isEmpty else { return nil }
            return InputProcess(bundleID: bundleID)
        }
    }

    private static func detail(
        inputs: [InputProcess],
        titles: [String],
        documents: [String],
        looked: Bool
    ) -> String {
        let bundles = Array(Set(inputs.map(\.bundleID))).sorted()
        guard !bundles.isEmpty else { return "" }
        var lines = ["入力: " + bundles.joined(separator: ", ")]
        guard looked else { return lines.joined(separator: "\n") }
        var seen: [String] = []
        for title in titles where title.contains("Meet") || MeetWindow.isLiveCall(title: title) {
            if !seen.contains(title) { seen.append(title) }
        }
        for document in documents where document.contains("meet.google.com") {
            if !seen.contains(document) { seen.append(document) }
        }
        let windows = seen.isEmpty ? "なし" : seen.prefix(4).joined(separator: " / ")
        lines.append("ウィンドウ: " + windows)
        return lines.joined(separator: "\n")
    }

    private static func browserWindows() -> [BrowserWindow] {
        let roots = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser"]
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return roots.contains(bundleID)
        }
        var windows: [BrowserWindow] = []
        for app in apps {
            let pid = app.processIdentifier
            for title in windowTitles(of: pid) {
                windows.append(BrowserWindow(title: title, document: ""))
            }
            if AXIsProcessTrusted() {
                windows.append(contentsOf: accessibilityWindows(of: pid))
            }
        }
        return windows
    }

    private static func windowTitles(of pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var titles: [String] = []
        for item in list {
            guard ownerPID(item) == pid else { continue }
            guard let title = item[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            titles.append(title)
        }
        return titles
    }

    private static func ownerPID(_ item: [String: Any]) -> pid_t? {
        if let pid = item[kCGWindowOwnerPID as String] as? pid_t { return pid }
        if let number = item[kCGWindowOwnerPID as String] as? NSNumber { return pid_t(number.int32Value) }
        return nil
    }

    private static func accessibilityWindows(of pid: pid_t) -> [BrowserWindow] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let value else { return [] }
        let elements: [AXUIElement]
        if let list = value as? [AXUIElement] {
            elements = list
        } else if let list = value as? NSArray {
            elements = (0..<list.count).map { unsafeBitCast(list[$0], to: AXUIElement.self) }
        } else {
            return []
        }
        return elements.map { element in
            BrowserWindow(title: stringAttr(element, kAXTitleAttribute), document: stringAttr(element, "AXDocument"))
        }
    }

    private static func stringAttr(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        if let text = value as? String { return text }
        return ""
    }

    private static func processIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(Self.systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
