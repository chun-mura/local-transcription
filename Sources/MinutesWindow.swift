import AppKit
import Foundation

@MainActor
final class MinutesController: NSObject {
    private var window: NSWindow?
    private var directory: URL?
    private var job: Task<Void, Never>?
    private var models: [String] = []
    private var ollamaNotice: String?
    private var promptWritable = true
    private var savedModel = ""
    private var statusGeneration = 0

    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let contextLabel = NSTextField(labelWithString: "文脈")
    private let contextField = NSTextField(string: "8192")
    private let promptView = NSTextView()
    private let saveDefault = NSButton(checkboxWithTitle: "この型を既定にする", target: nil, action: nil)
    private let makeButton = StampButton()
    private let stopButton = StampButton()
    private let openButton = StampButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let resultView = NSTextView()

    func show(directory: URL) {
        let window = self.window ?? makeWindow()
        self.window = window
        if job != nil, let current = self.directory, !SessionsRoot.same(current, directory) {
            message.stringValue = "作成中です。終わるまで別の記録には移れません"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let changed = self.directory.map { !SessionsRoot.same($0, directory) } ?? true
        if job == nil, changed {
            self.directory = directory
            loadForm()
            let existing = existingMinutes()
            resultView.string = existing
            if message.stringValue.isEmpty {
                if let notice = providerNotice() {
                    message.stringValue = notice
                } else if !existing.isEmpty {
                    message.stringValue = "以前の議事録を表示しています。作成すると置き換えます"
                }
            }
        }
        window.title = "議事録"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if models.isEmpty {
            Task { await self.refreshModels() }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "議事録"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Ink.paper
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard let content = window.contentView else { return window }
        content.wantsLayer = true
        content.layer?.backgroundColor = Ink.paper.cgColor

        providerPopup.addItems(withTitles: ["Apple Intelligence", "Ollama"])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providerPopup.font = Face.sans(13)

        modelPopup.font = Face.sans(13)
        contextLabel.font = Face.sans(12)
        contextLabel.textColor = Ink.faint
        contextField.font = Face.sans(13)
        contextField.textColor = Ink.ink
        contextField.placeholderString = "8192"
        contextField.focusRingType = .none
        contextField.toolTip = "Ollama が一度に読む長さ。短いと会議の前半が切れます"

        configure(promptView, editable: true)
        configure(resultView, editable: false)
        let promptScroll = scroll(promptView)
        let resultScroll = scroll(resultView)

        let promptLabel = NSTextField(labelWithString: "型")
        promptLabel.font = Face.sans(12)
        promptLabel.textColor = Ink.faint
        let resultLabel = NSTextField(labelWithString: "議事録")
        resultLabel.font = Face.sans(12)
        resultLabel.textColor = Ink.faint

        saveDefault.font = Face.sans(12)
        saveDefault.toolTip = "入れたときだけ、次からの初期値になります"

        makeButton.title = "作成"
        makeButton.onPress = { [weak self] in self?.start() }
        stopButton.title = "中止"
        stopButton.filled = false
        stopButton.isEnabled = false
        stopButton.onPress = { [weak self] in self?.stop() }
        openButton.title = "フォルダ"
        openButton.filled = false
        openButton.onPress = { [weak self] in self?.openFolder() }

        message.font = Face.sans(12)
        message.textColor = Ink.faint
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.cell?.truncatesLastVisibleLine = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let views: [NSView] = [
            providerPopup, modelPopup, contextLabel, contextField,
            promptLabel, promptScroll, saveDefault,
            makeButton, stopButton, openButton, message,
            resultLabel, resultScroll
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            providerPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            providerPopup.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            providerPopup.widthAnchor.constraint(equalToConstant: 180),

            modelPopup.leadingAnchor.constraint(equalTo: providerPopup.trailingAnchor, constant: 8),
            modelPopup.centerYAnchor.constraint(equalTo: providerPopup.centerYAnchor),
            modelPopup.widthAnchor.constraint(equalToConstant: 180),

            contextField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            contextField.centerYAnchor.constraint(equalTo: providerPopup.centerYAnchor),
            contextField.widthAnchor.constraint(equalToConstant: 72),
            contextField.heightAnchor.constraint(equalToConstant: 24),

            contextLabel.trailingAnchor.constraint(equalTo: contextField.leadingAnchor, constant: -6),
            contextLabel.centerYAnchor.constraint(equalTo: contextField.centerYAnchor),

            promptLabel.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            promptLabel.topAnchor.constraint(equalTo: providerPopup.bottomAnchor, constant: 14),

            promptScroll.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            promptScroll.trailingAnchor.constraint(equalTo: contextField.trailingAnchor),
            promptScroll.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            saveDefault.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
            saveDefault.topAnchor.constraint(equalTo: promptScroll.bottomAnchor, constant: 8),

            makeButton.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
            makeButton.topAnchor.constraint(equalTo: saveDefault.bottomAnchor, constant: 10),
            makeButton.widthAnchor.constraint(equalToConstant: 72),
            makeButton.heightAnchor.constraint(equalToConstant: 28),

            stopButton.leadingAnchor.constraint(equalTo: makeButton.trailingAnchor, constant: 8),
            stopButton.centerYAnchor.constraint(equalTo: makeButton.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 72),
            stopButton.heightAnchor.constraint(equalToConstant: 28),

            openButton.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor, constant: 8),
            openButton.centerYAnchor.constraint(equalTo: makeButton.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 92),
            openButton.heightAnchor.constraint(equalToConstant: 28),

            message.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: promptScroll.trailingAnchor),
            message.topAnchor.constraint(equalTo: makeButton.bottomAnchor, constant: 10),
            message.heightAnchor.constraint(equalToConstant: 32),

            resultLabel.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
            resultLabel.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 4),

            resultScroll.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: promptScroll.trailingAnchor),
            resultScroll.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 6),
            resultScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            resultScroll.heightAnchor.constraint(equalTo: promptScroll.heightAnchor)
        ])
        applyProviderVisibility()
        return window
    }

    private func loadForm() {
        guard let support = try? SessionsRoot.supportDirectory(create: true) else {
            message.stringValue = "設定を置けませんでした"
            return
        }
        message.stringValue = ""
        switch MinutesStore.loadPrompt(in: support) {
        case .ready(let text):
            promptView.string = text
            promptWritable = true
            saveDefault.isEnabled = true
        case .unreadable:
            promptView.string = MinutesText.defaultInstructions
            promptWritable = false
            saveDefault.state = .off
            saveDefault.isEnabled = false
            message.stringValue = "保存してある型を読めません。今回の欄だけ使います"
        }
        let settings = MinutesStore.loadSettings(in: support)
        providerPopup.selectItem(at: settings.provider == .ollama ? 1 : 0)
        contextField.stringValue = String(settings.numCtx)
        savedModel = settings.ollamaModel
        applyProviderVisibility()
        if !settings.ollamaModel.isEmpty {
            selectModel(settings.ollamaModel)
        }
    }

    private func existingMinutes() -> String {
        guard let directory else { return "" }
        let url = MinutesStore.minutesURL(in: directory)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return existing
    }

    private func providerNotice() -> String? {
        if providerPopup.indexOfSelectedItem == 0 {
            return AppleMinutes.unavailableReason()
        }
        return ollamaNotice
    }

    private func start() {
        guard job == nil, let directory, let window else { return }
        let instructions = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty {
            message.stringValue = "型を書いてください"
            return
        }
        let provider: MinutesProviderKind = providerPopup.indexOfSelectedItem == 1 ? .ollama : .apple
        let model = modelPopup.titleOfSelectedItem ?? ""
        let numCtx = MinutesText.clampContext(Int(contextField.stringValue) ?? 8192)
        contextField.stringValue = String(numCtx)
        if provider == .ollama, model.isEmpty || model == "—" {
            message.stringValue = ollamaNotice ?? "Ollama のモデルを選んでください"
            return
        }
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            message.stringValue = "文字起こしを読めませんでした"
            return
        }

        if let support = try? SessionsRoot.supportDirectory(create: true) {
            if saveDefault.state == .on {
                if !promptWritable {
                    message.stringValue = "保存してある型を読めないため、上書きしません"
                    return
                }
                do {
                    try MinutesStore.savePrompt(instructions, in: support)
                } catch {
                    message.stringValue = "型を保存できませんでした。チェックを外すと、今回だけの型で作れます"
                    return
                }
            }
            let remembered = model == "—" ? "" : model
            savedModel = remembered
            try? MinutesStore.saveSettings(
                MinutesSettings(provider: provider, ollamaModel: remembered, numCtx: numCtx),
                in: support
            )
        }

        setRunning(true)
        let generation = statusGeneration
        note("準備しています", generation: generation)
        let progress: @Sendable (String) -> Void = { text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MinutesProgressBus.post(text)
                }
            }
        }
        MinutesProgressBus.handler = { [weak self] text in
            self?.note(text, generation: generation)
        }
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome: MinutesOutcome
                switch provider {
                case .apple:
                    outcome = try await AppleMinutes.produce(
                        transcript: transcript,
                        instructions: instructions,
                        progress: progress
                    )
                case .ollama:
                    outcome = try await OllamaMinutes.produce(
                        transcript: transcript,
                        instructions: instructions,
                        model: model,
                        numCtx: numCtx,
                        progress: progress
                    )
                }
                try Task.checkCancellation()
                let written = try await self.commit(outcome, to: directory, on: window)
                self.finish(written)
            } catch is CancellationError {
                self.finish("中止しました。議事録は書いていません")
            } catch let failure as MinutesFailure {
                self.finish(failure.message)
            } catch {
                self.finish("議事録を作れませんでした")
            }
        }
    }

    private func commit(_ outcome: MinutesOutcome, to directory: URL, on window: NSWindow) async throws -> String {
        resultView.string = outcome.text
        let url = MinutesStore.minutesURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            let replace = await confirmReplace(on: window)
            try Task.checkCancellation()
            if !replace {
                return "書き込まずに残してあります"
            }
        }
        try Task.checkCancellation()
        do {
            try MinutesStore.writeMinutes(outcome.text, to: directory)
        } catch {
            return "議事録を書き込めませんでした。画面の文章は残しています"
        }
        if outcome.notesCut {
            return "minutes.md に書きました。長い部分は要約の時点で落ちています"
        }
        if outcome.outputCut {
            return "minutes.md に書きました。出力が文脈の上限で切れています"
        }
        return "minutes.md に書きました"
    }

    private func confirmReplace(on window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "議事録を置き換えますか"
            alert.informativeText = "minutes.md はすでにあります。"
            alert.addButton(withTitle: "置き換える")
            alert.addButton(withTitle: "残す")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func finish(_ text: String) {
        statusGeneration += 1
        MinutesProgressBus.handler = { _ in }
        job = nil
        setRunning(false)
        message.stringValue = text
    }

    private func note(_ text: String, generation: Int) {
        guard statusGeneration == generation else { return }
        message.stringValue = text
    }

    private func stop() {
        job?.cancel()
    }

    private func openFolder() {
        guard let directory else { return }
        NSWorkspace.shared.open(directory)
    }

    private func setRunning(_ running: Bool) {
        makeButton.isEnabled = !running
        stopButton.isEnabled = running
        providerPopup.isEnabled = !running
        modelPopup.isEnabled = !running
        contextField.isEnabled = !running
        promptView.isEditable = !running
        saveDefault.isEnabled = !running && promptWritable
    }

    @objc private func providerChanged(_ sender: Any?) {
        applyProviderVisibility()
        if providerPopup.indexOfSelectedItem == 1 {
            if let ollamaNotice, models.isEmpty {
                message.stringValue = ollamaNotice
            }
            Task { await refreshModels() }
        } else if let reason = AppleMinutes.unavailableReason() {
            message.stringValue = reason
        }
    }

    private func applyProviderVisibility() {
        let ollama = providerPopup.indexOfSelectedItem == 1
        modelPopup.isHidden = !ollama
        contextLabel.isHidden = !ollama
        contextField.isHidden = !ollama
    }

    private func refreshModels() async {
        do {
            let names = try await OllamaMinutes.listModels()
            models = names
            ollamaNotice = names.isEmpty ? "Ollama にモデルがありません。" : nil
            let saved = savedModel.isEmpty ? (modelPopup.titleOfSelectedItem ?? "") : savedModel
            modelPopup.removeAllItems()
            if names.isEmpty {
                modelPopup.addItem(withTitle: "—")
            } else {
                modelPopup.addItems(withTitles: names)
                if let pick = MinutesText.preferredModel(in: names, saved: saved) {
                    selectModel(pick)
                    savedModel = pick
                }
            }
            if providerPopup.indexOfSelectedItem == 1, let ollamaNotice {
                message.stringValue = ollamaNotice
            }
        } catch let failure as MinutesFailure {
            models = []
            ollamaNotice = failure.message
            modelPopup.removeAllItems()
            modelPopup.addItem(withTitle: "—")
            if providerPopup.indexOfSelectedItem == 1 {
                message.stringValue = failure.message
            }
        } catch {
            ollamaNotice = "Ollama が 127.0.0.1:11434 で応答しません。"
        }
    }

    private func selectModel(_ name: String) {
        if modelPopup.itemTitles.contains(name) {
            modelPopup.selectItem(withTitle: name)
        }
    }

    private func configure(_ text: NSTextView, editable: Bool) {
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.font = Face.sans(13)
        text.textColor = Ink.ink
        text.backgroundColor = Ink.sheet
        text.drawsBackground = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = NSRect(x: 0, y: 0, width: 560, height: 160)
    }

    private func scroll(_ text: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Ink.sheet
        scroll.borderType = .noBorder
        return scroll
    }
}

enum MinutesProgressBus {
    @MainActor static var handler: (String) -> Void = { _ in }

    @MainActor static func post(_ text: String) {
        handler(text)
    }
}
