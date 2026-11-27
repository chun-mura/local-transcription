import Foundation

@main
enum CallWatchTest {
    static func main() {
        ignoresShorterThanFourSeconds()
        startsOnceAtFourSeconds()
        shortGapDoesNotStop()
        stopsAfterThirtySeconds()
        leavesManualRecordingRunning()
        doesNotRestartTheSameCall()
        startsAgainOnTheNextCall()
        skipsAutoStartWhileBusy()
        hidesPromptWhileRecording()
        readsAndWritesSettings()
        matchesMeetWindows()
        matchesCallApps()
    }
}

private func ignoresShorterThanFourSeconds() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    expect(watch.tick(sample(at: 0, teams: true, settings: settings)), [])
    expect(watch.tick(sample(at: 3.9, teams: true, settings: settings)), [])
}

private func startsOnceAtFourSeconds() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    expect(watch.tick(sample(at: 0, teams: true, settings: settings)), [])
    expect(watch.tick(sample(at: 4, teams: true, settings: settings)), [.startRecording])
    expect(watch.tick(sample(at: 6, teams: true, recording: true, autoStarted: true, settings: settings)), [])
}

private func shortGapDoesNotStop() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    _ = watch.tick(sample(at: 0, teams: true, settings: settings))
    _ = watch.tick(sample(at: 4, teams: true, settings: settings))
    expect(watch.tick(sample(at: 6, teams: false, recording: true, autoStarted: true, settings: settings)), [])
    expect(watch.tick(sample(at: 16, teams: false, recording: true, autoStarted: true, settings: settings)), [])
    expect(watch.tick(sample(at: 17, teams: true, recording: true, autoStarted: true, settings: settings)), [])
}

private func stopsAfterThirtySeconds() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    _ = watch.tick(sample(at: 0, teams: true, settings: settings))
    _ = watch.tick(sample(at: 4, teams: true, settings: settings))
    expect(watch.tick(sample(at: 6, teams: false, recording: true, autoStarted: true, settings: settings)), [])
    expect(
        watch.tick(sample(at: 36, teams: false, recording: true, autoStarted: true, settings: settings)),
        [.stopRecording]
    )
}

private func leavesManualRecordingRunning() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    expect(watch.tick(sample(at: 0, teams: true, recording: true, settings: settings)), [])
    expect(watch.tick(sample(at: 4, teams: true, recording: true, settings: settings)), [])
    expect(watch.tick(sample(at: 5, teams: false, recording: true, settings: settings)), [])
    expect(watch.tick(sample(at: 35, teams: false, recording: true, settings: settings)), [])
}

private func doesNotRestartTheSameCall() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: false)
    _ = watch.tick(sample(at: 0, teams: true, settings: settings))
    expect(watch.tick(sample(at: 4, teams: true, settings: settings)), [.startRecording])
    expect(watch.tick(sample(at: 8, teams: true, settings: settings)), [])
    expect(watch.tick(sample(at: 10, teams: true, settings: settings)), [])

    var prompted = CallWatch()
    let ask = CallWatchSettings.off
    _ = prompted.tick(sample(at: 0, meet: true, settings: ask))
    expect(prompted.tick(sample(at: 4, meet: true, settings: ask)), [.showPrompt(.meet)])
    prompted.decline()
    expect(prompted.tick(sample(at: 8, meet: true, settings: ask)), [])
}

private func startsAgainOnTheNextCall() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    _ = watch.tick(sample(at: 0, teams: true, settings: settings))
    _ = watch.tick(sample(at: 4, teams: true, settings: settings))
    _ = watch.tick(sample(at: 6, teams: false, recording: true, autoStarted: true, settings: settings))
    expect(
        watch.tick(sample(at: 36, teams: false, recording: true, autoStarted: true, settings: settings)),
        [.stopRecording]
    )
    expect(watch.tick(sample(at: 40, teams: true, settings: settings)), [])
    expect(watch.tick(sample(at: 44, teams: true, settings: settings)), [.startRecording])
}

private func skipsAutoStartWhileBusy() {
    var watch = CallWatch()
    let settings = CallWatchSettings(autoStart: true, autoStop: true)
    _ = watch.tick(sample(at: 0, teams: true, preparing: true, settings: settings))
    expect(watch.tick(sample(at: 4, teams: true, preparing: true, settings: settings)), [])
    expect(watch.tick(sample(at: 8, teams: true, settings: settings)), [])
}

private func hidesPromptWhileRecording() {
    var watch = CallWatch()
    expect(watch.tick(sample(at: 0, teams: true, recording: true, settings: .off)), [])
    expect(watch.tick(sample(at: 4, teams: true, recording: true, settings: .off)), [])
    var shown = CallWatch()
    _ = shown.tick(sample(at: 0, teams: true, settings: .off))
    expect(shown.tick(sample(at: 4, teams: true, settings: .off)), [.showPrompt(.teams)])
    expect(shown.tick(sample(at: 6, teams: true, recording: true, settings: .off)), [.dismissPrompt])
}

private func readsAndWritesSettings() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("call-watch-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = CallWatchSettings.fileURL(in: directory)
    expect(CallWatchSettings.load(from: url), .off)
    let on = CallWatchSettings(autoStart: true, autoStop: true)
    try? on.save(to: url)
    expect(CallWatchSettings.load(from: url), on)
    try? "auto-start=0\nauto-stop=1\n".write(to: url, atomically: true, encoding: .utf8)
    expect(CallWatchSettings.load(from: url), .off)
    try? "nope\n".write(to: url, atomically: true, encoding: .utf8)
    expect(CallWatchSettings.load(from: url), .off)
    let stopped = on.settingAutoStart(false)
    expect(stopped.autoStart, false)
    expect(stopped.autoStop, false)
    expect(CallWatchSettings.off.settingAutoStop(true), .off)
    try? FileManager.default.removeItem(at: directory)
}

private func matchesMeetWindows() {
    expect(MeetWindow.isLiveCall(title: "Meet – 定例"), true)
    expect(MeetWindow.isLiveCall(title: "Meet - weekly"), true)
    expect(MeetWindow.isLiveCall(title: "abc-defg-hij"), true)
    expect(MeetWindow.isLiveCall(title: "会議 abc-defg-hij です"), true)
    expect(MeetWindow.isLiveCall(title: "xabc-defg-hij"), false)
    expect(MeetWindow.isLiveCall(title: "Google Meet"), false)
    expect(MeetWindow.isLiveCall(title: "Meet"), false)
    expect(MeetWindow.isLiveCall(document: "https://meet.google.com/abc-defg-hij"), true)
    expect(MeetWindow.isLiveCall(document: "https://meet.google.com/abc-defg-hij?authuser=0"), true)
    expect(MeetWindow.isLiveCall(document: "https://meet.google.com/landing"), false)
    expect(MeetWindow.isLiveCall(document: "https://meet.google.com/"), false)
    expect(MeetWindow.isLiveCall(document: "https://meet.google.com/new"), false)
}

private func matchesCallApps() {
    expect(CallApps.isTeams("com.microsoft.teams2"), true)
    expect(CallApps.isTeams("com.microsoft.teams2.helper"), true)
    expect(CallApps.isTeams("com.microsoft.teams2.modulehost"), true)
    expect(CallApps.isTeams("com.microsoft.teams"), true)
    expect(CallApps.isTeams("com.microsoft.teams.helper"), true)
    expect(CallApps.isTeams("com.microsoft.teams2.notificationcenter"), false)
    expect(CallApps.isMeetBrowser("com.google.Chrome.helper"), true)
    expect(CallApps.isMeetBrowser("com.apple.Safari"), true)
    expect(CallApps.isMeetBrowser("com.microsoft.edgemac"), true)
    expect(CallApps.isMeetBrowser("company.thebrowser.Browser"), true)
    expect(CallApps.isMeetBrowser("com.apple.WebKit.GPU"), false)
    expect(CallApps.isWebKitAudio("com.apple.WebKit.GPU"), true)
}

private func sample(
    at seconds: TimeInterval,
    teams: Bool = false,
    meet: Bool = false,
    recording: Bool = false,
    preparing: Bool = false,
    naming: Bool = false,
    resetting: Bool = false,
    autoStarted: Bool = false,
    settings: CallWatchSettings
) -> CallWatchInput {
    CallWatchInput(
        now: Date(timeIntervalSince1970: seconds),
        teams: teams,
        meet: meet,
        recording: recording,
        preparing: preparing,
        naming: naming,
        resetting: resetting,
        autoStarted: autoStarted,
        settings: settings
    )
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}
