import Foundation

@main
enum DisplayTest {
    static func main() {
        showsUntilTheNextRecordingStarts()
        clearsOnlyAfterTheCaptureSucceeds()
        keepsThePreviousScreenWhenStartFails()
        cancelAfterReleaseLeavesTheNewGeneration()
        bumpDropsAHeldStart()
    }
}

private func showsUntilTheNextRecordingStarts() {
    let gate = DisplayGate()
    expect(gate.intake(.line("前の録音")), .show(0))
    expect(gate.release(), nil)
}

private func clearsOnlyAfterTheCaptureSucceeds() {
    let gate = DisplayGate()
    gate.hold()
    expect(gate.current(), 1)
    expect(gate.intake(.line("新しい")), .held)
    expect(gate.intake(.system("途中")), .held)
    expect(gate.intake(.microphone("自分")), .held)
    expect(gate.intake(.notice("区切り")), .held)
    expect(
        gate.release(),
        DisplayGate.Release(
            generation: 1,
            pending: [.line("新しい"), .system("途中"), .microphone("自分"), .notice("区切り")]
        )
    )
    expect(gate.intake(.line("続き")), .show(1))
    expect(gate.release(), nil)
}

private func keepsThePreviousScreenWhenStartFails() {
    let gate = DisplayGate()
    expect(gate.intake(.line("前の録音")), .show(0))
    gate.hold()
    expect(gate.intake(.line("始まらなかった")), .held)
    gate.cancel()
    expect(gate.release(), nil)
    expect(gate.current(), 2)
    expect(gate.intake(.line("そのあと")), .show(2))
    gate.cancel()
    expect(gate.current(), 2)
}

private func cancelAfterReleaseLeavesTheNewGeneration() {
    let gate = DisplayGate()
    gate.hold()
    expect(gate.intake(.line("最初の行")), .held)
    expect(gate.release()?.generation, 1)
    gate.cancel()
    expect(gate.current(), 1)
    expect(gate.intake(.line("続き")), .show(1))
}

private func bumpDropsAHeldStart() {
    let gate = DisplayGate()
    gate.hold()
    expect(gate.intake(.line("途中")), .held)
    gate.bump()
    expect(gate.release(), nil)
    expect(gate.current(), 2)
    expect(gate.intake(.line("リセット後")), .show(2))
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    if actual == expected { return }
    fputs("expected \(expected), got \(actual)\n", stderr)
    exit(1)
}
