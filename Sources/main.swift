import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Speech

enum PermissionTarget: Sendable {
    case microphone
    case screen
}

final class UIHooks: @unchecked Sendable {
    var status: @Sendable (String) -> Void = { _ in }
    var line: @Sendable (String) -> Void = { _ in }
    var volatile: @Sendable (Speaker, String) -> Void = { _, _ in }
    var path: @Sendable (String?) -> Void = { _ in }
    var permission: @Sendable (PermissionTarget?) -> Void = { _ in }
    var notice: @Sendable (String) -> Void = { _ in }
    var running: @Sendable (Bool) -> Void = { _ in }
    var preparing: @Sendable (Bool) -> Void = { _ in }
    var finish: @Sendable (URL, @escaping @Sendable () -> Void) -> Void = { _, done in done() }
}

final class Router: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SessionStore?
    private var system: LiveChannel?
    private var microphone: LiveChannel?

    func set(store: SessionStore, system: LiveChannel, microphone: LiveChannel) {
        lock.lock()
        self.store = store
        self.system = system
        self.microphone = microphone
        lock.unlock()
    }

    func clear() {
        lock.lock()
        store = nil
        system = nil
        microphone = nil
        lock.unlock()
    }

    func ingest(_ speaker: Speaker, _ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let store = store
        let channel = speaker == .system ? system : microphone
        lock.unlock()
        store?.write(speaker, buffer: buffer)
        channel?.append(buffer)
    }

    func appendTranscript(_ speaker: Speaker, text: String, at date: Date) -> String? {
        lock.lock()
        let store = store
        lock.unlock()
        return store?.append(speaker: speaker, text: text, at: date)
    }
}

actor Engine {
    private let hooks: UIHooks
    private let router = Router()
    private let capture = SystemCapture()
    private let maxSeconds: TimeInterval
    private var system: LiveChannel?
    private var microphone: LiveChannel?
    private var store: SessionStore?
    private var sessionLocale: Locale?
    private var sessionFormat: AVAudioFormat?
    private var active = false
    private var busy = false
    private var rotating = false
    private var awaitingTitle = false
    private var generation = 0
    private var limitTask: Task<Void, Never>?

    init(hooks: UIHooks) {
        self.hooks = hooks
        if let raw = ProcessInfo.processInfo.environment["SESSION_MAX_SECONDS"],
           let value = TimeInterval(raw), value >= 1 {
            maxSeconds = value
        } else {
            maxSeconds = 7_200
        }
    }

    func start() async {
        guard !active, !busy, !rotating, !awaitingTitle else { return }
        busy = true
        let token = generation
        hooks.preparing(true)
        hooks.permission(nil)
        defer {
            busy = false
            hooks.preparing(false)
        }
        do {
            try await ensurePermissions()
            hooks.status("日本語の認識モデルを確認しています")
            guard let locale = await SpeechSetup.japaneseLocale() else {
                throw EngineError.japaneseUnavailable
            }
            let probe = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
            try await SpeechSetup.installModel(for: [probe]) { [hooks] message in
                hooks.status(message)
            }
            guard let format = await SpeechSetup.chooseFormat(for: probe) else {
                throw EngineError.formatUnavailable
            }
            fputs("認識の形式: \(format)\n", stderr)
            try await startSession(locale: locale, format: format, token: token)
        } catch {
            hooks.running(false)
            hooks.status(error.localizedDescription)
            if let engineError = error as? EngineError {
                switch engineError {
                case .microphoneDenied:
                    hooks.permission(.microphone)
                case .screenDenied:
                    hooks.permission(.screen)
                default:
                    hooks.permission(nil)
                }
            }
        }
    }

    func stop() async {
        generation += 1
        limitTask?.cancel()
        guard active else { return }
        let directory = await teardown()
        await deliver(directory, status: "停止中")
    }

    private func startSession(locale: Locale, format: AVAudioFormat, token: Int) async throws {
        let store = try SessionStore.create(format: format)
        let system = LiveChannel(speaker: .system, locale: locale, format: format)
        let microphone = LiveChannel(speaker: .microphone, locale: locale, format: format)
        wire(system)
        wire(microphone)
        do {
            try await system.prepare()
            try await microphone.prepare()
        } catch {
            await system.finish()
            await microphone.finish()
            store.discard()
            throw error
        }

        self.store = store
        self.system = system
        self.microphone = microphone
        self.sessionLocale = locale
        self.sessionFormat = format
        router.set(store: store, system: system, microphone: microphone)
        installHandlers()

        do {
            try await beginCapture(format)
        } catch {
            await capture.stop()
            await system.finish()
            await microphone.finish()
            router.clear()
            store.discard()
            self.store = nil
            self.system = nil
            self.microphone = nil
            hooks.path(nil)
            throw error
        }

        guard generation == token else {
            await capture.stop()
            await system.finish()
            await microphone.finish()
            router.clear()
            store.close()
            let directory = store.directory
            self.store = nil
            self.system = nil
            self.microphone = nil
            hooks.path(directory.path)
            hooks.running(false)
            await deliver(directory, status: "停止中")
            return
        }

        active = true
        hooks.path(store.directory.path)
        hooks.running(true)
        hooks.status(runningStatus())
        armLimit()
    }

    private func beginCapture(_ format: AVAudioFormat) async throws {
        do {
            try await capture.start(
                captureRate: Int(format.sampleRate),
                channels: Int(format.channelCount),
                output: format
            )
        } catch {
            let alreadyFallback = Int(format.sampleRate) == 48_000 && format.channelCount == 1
            if alreadyFallback { throw error }
            fputs("指定した形式で開始できなかったため、48 kHz・モノラルで再試行します: \(error)\n", stderr)
            try await capture.start(captureRate: 48_000, channels: 1, output: format)
        }
    }

    private func wire(_ channel: LiveChannel) {
        let speaker = channel.speaker
        channel.onFinal = { [router, hooks] text in
            let text = FinalReplacements.apply(text)
            guard let line = router.appendTranscript(speaker, text: text, at: Date()) else { return }
            hooks.line(line)
        }
        channel.onVolatile = { [hooks] text in
            hooks.volatile(speaker, text)
        }
        channel.onFailure = { [hooks] message in
            hooks.status(message)
        }
        if speaker == .microphone {
            channel.onLag = { [capture, hooks] in
                capture.preferDecimation()
                hooks.status("自分の字幕が2秒以上遅れたため、マイクの変換を切り替えました")
            }
        }
    }

    nonisolated func installHandlers() {
        capture.onBuffer = { [router] speaker, buffer in
            router.ingest(speaker, buffer)
        }
        capture.onStopped = { message in
            Task { await self.unexpectedStop(message) }
        }
    }

    private func unexpectedStop(_ message: String) async {
        guard active else { return }
        generation += 1
        let directory = await teardown()
        await deliver(directory, status: message)
    }

    private func armLimit() {
        generation += 1
        let token = generation
        let maxSeconds = maxSeconds
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            await self?.rotate(token: token)
        }
    }

    private func rotate(token: Int) async {
        guard token == generation, active, let locale = sessionLocale, let format = sessionFormat else { return }
        rotating = true
        defer { rotating = false }
        hooks.notice("—— ここまでを保存し、新しいファイルを開始しました ——")
        await teardown(updateUI: false)
        guard token == generation else {
            hooks.running(false)
            hooks.status("停止中")
            return
        }
        do {
            try await startSession(locale: locale, format: format, token: token)
        } catch {
            hooks.running(false)
            hooks.status(error.localizedDescription)
        }
    }

    @discardableResult
    private func teardown(updateUI: Bool = true) async -> URL? {
        let directory = store?.directory
        active = false
        limitTask?.cancel()
        await capture.stop()
        await system?.finish()
        await microphone?.finish()
        store?.close()
        router.clear()
        store = nil
        system = nil
        microphone = nil
        if updateUI {
            hooks.running(false)
        }
        return directory
    }

    private func deliver(_ directory: URL?, status: String) async {
        guard let directory else { return }
        awaitingTitle = true
        defer { awaitingTitle = false }
        hooks.status(status)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            hooks.finish(directory) {
                continuation.resume()
            }
        }
    }

    private func runningStatus() -> String {
        if maxSeconds == 7_200 {
            return "録音中"
        }
        return "録音中（\(Int(maxSeconds))秒で区切ります）"
    }

    private func ensurePermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !granted { throw EngineError.microphoneDenied }
        default:
            throw EngineError.microphoneDenied
        }
        if !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() {
                throw EngineError.screenDenied
            }
        }
    }
}

@main
struct Entry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let hooks = UIHooks()
    private let engine: Engine
    private var window: NSWindow?
    private var statusLabel = FittingTextField(labelWithString: "停止中")
    private var opponentLine = FittingTextField(labelWithString: "相手　…")
    private var selfLine = FittingTextField(labelWithString: "自分　…")
    private let latestButton = StampButton()
    private let hotKey = RecordingHotKey()
    private var closingAfterStop = false
    private var pathLabel = NSTextField(labelWithString: "")
    private var textView = NSTextView()
    private var scrollView = NSScrollView()
    private let startButton = StampButton()
    private let sideButton = StampButton()
    private let recordsButton = StampButton()
    private let seal = SealDot()
    private var sessionPath: String?
    private var permissionTarget: PermissionTarget?
    private var running = false
    private var preparing = false
    private var naming = false
    private var recordings: RecordingsController?

    override init() {
        engine = Engine(hooks: hooks)
        super.init()
        wire()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        hotKey.onPress = { [weak self] in
            self?.toggleRecording(nil)
        }
        hotKey.install()
        let window = makeWindow()
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await engine.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func wire() {
        hooks.status = { [weak self] text in
            Task { @MainActor in self?.statusLabel.stringValue = text }
        }
        hooks.line = { [weak self] line in
            Task { @MainActor in self?.appendLine(line) }
        }
        hooks.volatile = { [weak self] speaker, text in
            Task { @MainActor in self?.setVolatile(speaker, text) }
        }
        hooks.path = { [weak self] path in
            Task { @MainActor in
                self?.sessionPath = path
                self?.pathLabel.stringValue = path ?? ""
                self?.refreshSideButton()
                self?.recordings?.reload(selecting: nil)
            }
        }
        hooks.permission = { [weak self] target in
            Task { @MainActor in
                self?.permissionTarget = target
                self?.refreshSideButton()
            }
        }
        hooks.notice = { [weak self] text in
            Task { @MainActor in self?.appendNotice(text) }
        }
        hooks.running = { [weak self] running in
            Task { @MainActor in
                self?.running = running
                self?.seal.active = running
                self?.refreshStartButton()
                self?.recordings?.noteActivityChanged()
                if !running {
                    self?.setVolatile(.system, "")
                    self?.setVolatile(.microphone, "")
                }
            }
        }
        hooks.preparing = { [weak self] preparing in
            Task { @MainActor in
                self?.preparing = preparing
                self?.refreshStartButton()
            }
        }
        hooks.finish = { [weak self] url, done in
            Task { @MainActor in
                await self?.offerTitle(for: url)
                done()
            }
        }
    }

    private func refreshStartButton() {
        if naming {
            startButton.title = "停止"
            startButton.isEnabled = false
        } else if preparing && !running {
            startButton.title = "準備中"
            startButton.isEnabled = false
        } else if running {
            startButton.title = "停止"
            startButton.isEnabled = true
        } else {
            startButton.title = "開始"
            startButton.isEnabled = true
        }
        startButton.toolTip = "⌘⇧R"
    }

    @objc func toggleRecording(_ sender: Any?) {
        pressStart()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingAfterStop || !running {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "録音を止めて終了しますか"
        alert.informativeText = "ここまでの文字と音声は保存されます。"
        alert.addButton(withTitle: "止めて終了")
        alert.addButton(withTitle: "録音を続ける")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.closingAfterStop = true
            Task { @MainActor in
                await self.engine.stop()
                sender.close()
            }
        }
        return false
    }

    private func installMenu() {
        let appMenu = NSMenu()
        let toggle = NSMenuItem(title: "録音の開始と停止", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        appMenu.addItem(toggle)
        let archive = NSMenuItem(title: "これまでの記録", action: #selector(showRecordingsMenu(_:)), keyEquivalent: "")
        archive.target = self
        appMenu.addItem(archive)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    private func refreshSideButton() {
        if permissionTarget != nil {
            sideButton.title = "設定"
            sideButton.isEnabled = true
        } else {
            sideButton.title = "フォルダ"
            sideButton.isEnabled = sessionPath != nil
        }
    }

    private func pressStart() {
        guard !naming else { return }
        Task {
            if running {
                await engine.stop()
            } else {
                await engine.start()
            }
        }
    }

    private func offerTitle(for directory: URL) async {
        naming = true
        refreshStartButton()
        defer {
            naming = false
            refreshStartButton()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        let entered = await askTitle(existing: SessionCatalog.title(in: directory))
        do {
            let renamed = try SessionCatalog.apply(title: entered, to: directory)
            if samePath(sessionPath, directory.path) {
                sessionPath = renamed.path
                pathLabel.stringValue = renamed.path
                refreshSideButton()
            }
            recordings?.reload(selecting: renamed)
        } catch {
            statusLabel.stringValue = "名前を付けられませんでした"
        }
    }

    private func askTitle(existing: String) async -> String {
        let alert = NSAlert()
        alert.messageText = "この録音の名前"
        alert.informativeText = "空のまま保存できます。あとから一覧で変えられます。"
        alert.addButton(withTitle: "保存")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = existing
        field.placeholderString = "企画定例"
        field.font = Face.sans(14)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window else {
            alert.runModal()
            return field.stringValue
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { _ in
                continuation.resume(returning: field.stringValue)
            }
        }
    }

    private func showRecordings() {
        if recordings == nil {
            let controller = RecordingsController()
            controller.onRename = { [weak self] oldPath, newPath in
                guard let self, self.samePath(self.sessionPath, oldPath) else { return }
                self.sessionPath = newPath
                self.pathLabel.stringValue = newPath
                self.refreshSideButton()
            }
            controller.isActive = { [weak self] path in
                guard let self else { return false }
                return self.running && self.samePath(self.sessionPath, path)
            }
            recordings = controller
        }
        recordings?.show()
    }

    @objc private func showRecordingsMenu(_ sender: Any?) {
        showRecordings()
    }

    private func samePath(_ stored: String?, _ other: String) -> Bool {
        guard let stored else { return false }
        return URL(fileURLWithPath: stored).standardizedFileURL.path == URL(fileURLWithPath: other).standardizedFileURL.path
    }

    private func pressSide() {
        if let permissionTarget {
            let key = permissionTarget == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let sessionPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: sessionPath))
    }

    private func setVolatile(_ speaker: Speaker, _ text: String) {
        let field = speaker == .system ? opponentLine : selfLine
        let spoken = text.isEmpty ? Ink.faint : (speaker == .microphone ? Ink.ink : Ink.other)
        let body = text.isEmpty ? "…" : text
        let line = NSMutableAttributedString(string: "\(speaker.label)　", attributes: [
            .font: Face.sans(13),
            .foregroundColor: spoken
        ])
        line.append(NSAttributedString(string: body, attributes: [
            .font: Face.mincho(16),
            .foregroundColor: spoken
        ]))
        field.attributedStringValue = line
    }

    private func appendLine(_ line: String) {
        let parsed = ParsedLine(line)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: parsed.time + "  ", attributes: [
            .font: Face.sans(12),
            .foregroundColor: Ink.faint,
            .paragraphStyle: paragraph
        ]))
        result.append(NSAttributedString(string: parsed.label + "  ", attributes: [
            .font: Face.sans(13),
            .foregroundColor: parsed.label == "自分" ? Ink.ink : Ink.other,
            .paragraphStyle: paragraph
        ]))
        result.append(NSAttributedString(string: parsed.text + "\n", attributes: [
            .font: Face.mincho(17),
            .foregroundColor: Ink.ink,
            .paragraphStyle: paragraph
        ]))
        prepend(result)
    }

    private func appendNotice(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.alignment = .center
        prepend(NSAttributedString(string: text + "\n", attributes: [
            .font: Face.sans(12),
            .foregroundColor: Ink.faint,
            .paragraphStyle: paragraph
        ]))
    }

    private func prepend(_ string: NSAttributedString) {
        guard let storage = textView.textStorage else { return }
        let clip = scrollView.contentView
        let oldOrigin = clip.bounds.origin
        let atTop = storage.length == 0 || oldOrigin.y <= 8
        let oldHeight = usedTextHeight()
        storage.insert(string, at: 0)
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
        }
        if atTop {
            clip.scroll(to: NSPoint(x: oldOrigin.x, y: 0))
        } else {
            let delta = usedTextHeight() - oldHeight
            clip.scroll(to: NSPoint(x: oldOrigin.x, y: oldOrigin.y + delta))
        }
        scrollView.reflectScrolledClipView(clip)
        updateLatestButton()
    }

    private func scrollToLatest() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clip)
        latestButton.isHidden = true
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        updateLatestButton()
    }

    private func updateLatestButton() {
        let atTop = textView.string.isEmpty || scrollView.contentView.bounds.origin.y <= 8
        latestButton.isHidden = atTop
    }

    private func usedTextHeight() -> CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        return layout.usedRect(for: container).height
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "記録音"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Ink.paper
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 560, height: 480)
        window.center()

        guard let content = window.contentView else { return window }
        content.wantsLayer = true
        content.layer?.backgroundColor = Ink.paper.cgColor

        let title = NSTextField(labelWithString: "記録音")
        title.font = Face.mincho(28)
        title.textColor = Ink.ink
        styleField(title)

        styleField(statusLabel, maxLines: 2)
        statusLabel.font = Face.sans(13)
        statusLabel.textColor = Ink.ink

        styleField(opponentLine, maxLines: 3)
        styleField(selfLine, maxLines: 3)

        let hint = NSTextField(labelWithString: "ヘッドホンを付けて使ってください。スピーカーだと、相手の声が「自分」にも入ります。")
        styleField(hint, maxLines: 2)
        hint.font = Face.sans(12)
        hint.textColor = Ink.faint
        hint.preferredMaxLayoutWidth = 480

        styleField(pathLabel)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = Face.sans(11)
        pathLabel.textColor = Ink.faint
        pathLabel.isSelectable = true

        startButton.title = "開始"
        startButton.toolTip = "⌘⇧R"
        sideButton.title = "フォルダ"
        sideButton.isEnabled = false
        recordsButton.title = "記録"
        recordsButton.filled = false
        recordsButton.toolTip = "これまでの記録"
        startButton.onPress = { [weak self] in self?.pressStart() }
        sideButton.onPress = { [weak self] in self?.pressSide() }
        recordsButton.onPress = { [weak self] in self?.showRecordings() }
        latestButton.title = "最新へ"
        latestButton.filled = false
        latestButton.isHidden = true
        latestButton.toolTip = "一番新しい行へ戻る"
        latestButton.onPress = { [weak self] in self?.scrollToLatest() }

        let sheet = NSView()
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = Ink.sheet.cgColor
        let margin = MarginLine()

        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Ink.sheet
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.font = Face.mincho(17)
        textView.textColor = Ink.ink
        textView.selectedTextAttributes = [
            .backgroundColor: Ink.ink.withAlphaComponent(0.16),
            .foregroundColor: Ink.ink
        ]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        stayWithinWindow(textView)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Ink.sheet
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        stayWithinWindow(scrollView)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let views = [title, seal, statusLabel, recordsButton, sideButton, startButton, sheet, margin, opponentLine, selfLine, scrollView, latestButton, hint, pathLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            if view === margin || view === opponentLine || view === selfLine || view === scrollView || view === latestButton {
                sheet.addSubview(view)
            } else if view !== sheet {
                content.addSubview(view)
            }
        }
        content.addSubview(sheet)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),

            seal.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            seal.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            seal.widthAnchor.constraint(equalToConstant: 12),
            seal.heightAnchor.constraint(equalToConstant: 12),

            startButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            startButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            startButton.widthAnchor.constraint(equalToConstant: 92),
            startButton.heightAnchor.constraint(equalToConstant: 34),

            sideButton.trailingAnchor.constraint(equalTo: startButton.leadingAnchor, constant: -8),
            sideButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            sideButton.widthAnchor.constraint(equalToConstant: 92),
            sideButton.heightAnchor.constraint(equalToConstant: 34),

            recordsButton.trailingAnchor.constraint(equalTo: sideButton.leadingAnchor, constant: -8),
            recordsButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            recordsButton.widthAnchor.constraint(equalToConstant: 72),
            recordsButton.heightAnchor.constraint(equalToConstant: 34),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            sheet.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            sheet.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            sheet.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            sheet.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -14),

            margin.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 16),
            margin.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 10),
            margin.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -10),
            margin.widthAnchor.constraint(equalToConstant: 8),

            opponentLine.leadingAnchor.constraint(equalTo: margin.trailingAnchor, constant: 12),
            opponentLine.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -16),
            opponentLine.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 12),

            selfLine.leadingAnchor.constraint(equalTo: opponentLine.leadingAnchor),
            selfLine.trailingAnchor.constraint(equalTo: opponentLine.trailingAnchor),
            selfLine.topAnchor.constraint(equalTo: opponentLine.bottomAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: margin.trailingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: selfLine.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: sheet.bottomAnchor),

            latestButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            latestButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -12),
            latestButton.widthAnchor.constraint(equalToConstant: 72),
            latestButton.heightAnchor.constraint(equalToConstant: 26),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            hint.bottomAnchor.constraint(equalTo: pathLabel.topAnchor, constant: -4),

            pathLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            pathLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            pathLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
        setVolatile(.system, "")
        setVolatile(.microphone, "")
        return window
    }

    private func styleField(_ field: NSTextField, maxLines: Int = 1) {
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.backgroundColor = .clear
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = maxLines > 1 ? .byWordWrapping : .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        if maxLines > 1 {
            field.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        stayWithinWindow(field)
    }

    private func stayWithinWindow(_ view: NSView) {
        let priority = NSLayoutConstraint.Priority.defaultLow
        view.setContentCompressionResistancePriority(priority, for: .horizontal)
        view.setContentHuggingPriority(priority, for: .horizontal)
    }
}

private struct ParsedLine {
    var time: String
    var label: String
    var text: String

    init(_ line: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
            time = ""
            label = ""
            text = line
            return
        }
        time = String(line[line.index(after: line.startIndex)..<close])
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        if rest.hasPrefix("自分") {
            label = "自分"
        } else if rest.hasPrefix("相手") {
            label = "相手"
        } else {
            label = ""
        }
        text = String(rest.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class RecordingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onRename: (String, String) -> Void = { _, _ in }
    var isActive: (String) -> Bool = { _ in false }

    private var window: NSWindow?
    private var table = NSTableView()
    private var records: [Recording] = []
    private let nameField = NSTextField(string: "")
    private let message = NSTextField(labelWithString: "")
    private let applyButton = StampButton()
    private let openButton = StampButton()

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        reload(selecting: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func reload(selecting directory: URL?) {
        let stamp = directory.flatMap { SessionCatalog.splitFolderName($0.lastPathComponent)?.stamp }
            ?? selectedStamp()
        records = SessionCatalog.recordings()
        table.reloadData()
        if let stamp, let row = records.firstIndex(where: { $0.stamp == stamp }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        syncEditor()
    }

    func noteActivityChanged() {
        syncEditor()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, records.indices.contains(row) else { return nil }
        let record = records[row]
        let cell = reuseCell(tableView, column: tableColumn)
        let value: String
        let color: NSColor
        switch tableColumn.identifier.rawValue {
        case "when":
            value = record.when
            color = Ink.faint
        case "title":
            value = record.title.isEmpty ? "名前なし" : record.title
            color = record.title.isEmpty ? Ink.faint : Ink.ink
        default:
            value = record.excerpt.isEmpty ? "—" : record.excerpt
            color = record.excerpt.isEmpty ? Ink.faint : Ink.other
        }
        cell.textField?.stringValue = value
        cell.textField?.textColor = color
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncEditor()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "これまでの記録"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Ink.paper
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        guard let content = window.contentView else { return window }
        content.wantsLayer = true
        content.layer?.backgroundColor = Ink.paper.cgColor

        table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.backgroundColor = Ink.sheet
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 8, height: 6)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.addTableColumn(column("when", "日時", 156))
        table.addTableColumn(column("title", "名前", 160))
        let excerpt = column("excerpt", "最初の相手", 280)
        excerpt.resizingMask = .autoresizingMask
        table.addTableColumn(excerpt)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Ink.sheet
        scroll.borderType = .noBorder

        nameField.font = Face.sans(13)
        nameField.textColor = Ink.ink
        nameField.placeholderString = "この録音の名前"
        nameField.focusRingType = .none
        nameField.target = self
        nameField.action = #selector(applyName(_:))

        message.font = Face.sans(12)
        message.textColor = Ink.faint
        message.lineBreakMode = .byTruncatingTail

        applyButton.title = "付ける"
        applyButton.onPress = { [weak self] in self?.applyName(nil) }
        openButton.title = "フォルダ"
        openButton.filled = false
        openButton.onPress = { [weak self] in self?.openSelected(nil) }

        let views = [scroll, nameField, message, applyButton, openButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: nameField.topAnchor, constant: -16),

            nameField.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            nameField.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            nameField.heightAnchor.constraint(equalToConstant: 26),

            applyButton.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
            applyButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            applyButton.widthAnchor.constraint(equalToConstant: 72),
            applyButton.heightAnchor.constraint(equalToConstant: 28),

            openButton.leadingAnchor.constraint(equalTo: applyButton.trailingAnchor, constant: 8),
            openButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            openButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 92),
            openButton.heightAnchor.constraint(equalToConstant: 28),

            message.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            message.heightAnchor.constraint(equalToConstant: 16)
        ])
        return window
    }

    private func column(_ identifier: String, _ title: String, _ width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 80
        return column
    }

    private func reuseCell(_ tableView: NSTableView, column: NSTableColumn) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = column.identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = Face.sans(13)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func selectedStamp() -> String? {
        let row = table.selectedRow
        guard records.indices.contains(row) else { return nil }
        return records[row].stamp
    }

    private func syncEditor() {
        let row = table.selectedRow
        guard records.indices.contains(row) else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            applyButton.isEnabled = false
            openButton.isEnabled = false
            message.stringValue = records.isEmpty ? "まだ記録はありません" : "記録を選んでください"
            return
        }
        let record = records[row]
        let active = isActive(record.directory.path)
        nameField.stringValue = record.title
        nameField.isEnabled = !active
        applyButton.isEnabled = !active
        openButton.isEnabled = true
        message.stringValue = active ? "録音中です。停止したときに名前を付けられます" : ""
    }

    @objc private func applyName(_ sender: Any?) {
        let row = table.selectedRow
        guard records.indices.contains(row) else { return }
        let record = records[row]
        if isActive(record.directory.path) {
            message.stringValue = "録音中です。停止したときに名前を付けられます"
            return
        }
        do {
            let renamed = try SessionCatalog.apply(title: nameField.stringValue, to: record.directory)
            onRename(record.directory.path, renamed.path)
            reload(selecting: renamed)
        } catch {
            message.stringValue = "名前を付けられませんでした"
        }
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard records.indices.contains(row) else { return }
        NSWorkspace.shared.open(records[row].directory)
    }
}

enum Ink {
    static let paper = NSColor(calibratedRed: 0.102, green: 0.102, blue: 0.110, alpha: 1)
    static let sheet = NSColor(calibratedRed: 0.165, green: 0.165, blue: 0.176, alpha: 1)
    static let lift = NSColor(calibratedRed: 0.280, green: 0.280, blue: 0.300, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.910, green: 0.905, blue: 0.890, alpha: 1)
    static let other = NSColor(calibratedRed: 0.730, green: 0.750, blue: 0.780, alpha: 1)
    static let faint = NSColor(calibratedRed: 0.620, green: 0.615, blue: 0.590, alpha: 1)
    static let seal = NSColor(calibratedRed: 0.890, green: 0.230, blue: 0.200, alpha: 1)
}

enum Face {
    static func mincho(_ size: CGFloat) -> NSFont {
        NSFont(name: "HiraginoMincho-ProN-W3", size: size)
            ?? NSFont(name: "Hiragino Mincho ProN W3", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    static func sans(_ size: CGFloat) -> NSFont {
        NSFont(name: "HiraginoSans-W3", size: size)
            ?? NSFont(name: "Hiragino Sans W3", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}

final class FittingTextField: NSTextField {
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 1, abs(preferredMaxLayoutWidth - width) > 0.5 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}

final class StampButton: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var filled = true { didSet { needsDisplay = true } }
    var onPress: () -> Void = {}
    private var pressed = false

    override var intrinsicContentSize: NSSize {
        filled ? NSSize(width: 92, height: 34) : NSSize(width: 72, height: 26)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fire = pressed && bounds.contains(point) && isEnabled
        pressed = false
        needsDisplay = true
        if fire { onPress() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = pressed ? bounds.offsetBy(dx: 1, dy: -1) : bounds
        let fill = filled ? (isEnabled ? Ink.ink : Ink.lift) : Ink.lift
        let foreground = filled ? (isEnabled ? Ink.paper : Ink.faint) : Ink.ink
        fill.setFill()
        rect.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: Face.sans(filled ? 13 : 12),
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ])
        let size = text.size()
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress()
        return true
    }
}

final class SealDot: NSView {
    var active = false {
        didSet {
            if active {
                start()
            } else {
                timer?.invalidate()
                timer = nil
                bright = true
                needsDisplay = true
            }
        }
    }

    private var timer: Timer?
    private var bright = true

    override func draw(_ dirtyRect: NSRect) {
        let color = active ? Ink.seal.withAlphaComponent(bright ? 1 : 0.35) : Ink.faint.withAlphaComponent(0.35)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bright.toggle()
                self.needsDisplay = true
            }
        }
    }
}

final class RecordingHotKey {
    var onPress: (@MainActor () -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<RecordingHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    hotKey.onPress?()
                }
            }
            return noErr
        }, 1, &spec, pointer, &handler)
        let signature = OSType(UInt32(0x4C) << 24 | UInt32(0x54) << 16 | UInt32(0x53) << 8 | UInt32(0x52))
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr {
            fputs("ショートカットを登録できませんでした: \(status)\n", stderr)
        }
    }
}

final class MarginLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Ink.lift.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.midX, y: 0))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.height))
        path.lineWidth = 1.5
        path.stroke()
    }
}
