import Foundation

@main
enum TitlePromptTest {
    static func main() {
        staysQueuedWhileAnotherAppIsFront()
        waitsUntilRecordingStops()
        asksInStopOrder()
    }
}

private func staysQueuedWhileAnotherAppIsFront() {
    var queue = TitlePromptQueue()
    queue.add("/tmp/20261105-130000")
    let behind = TitlePrompt(appActive: false, recording: false, preparing: false, resetting: false, askingReset: false)
    expect(queue.next(when: behind), nil)
    expect(queue.paths, ["/tmp/20261105-130000"])

    let returned = TitlePrompt(appActive: true, recording: false, preparing: false, resetting: false, askingReset: false)
    expect(queue.next(when: returned), "/tmp/20261105-130000")
    expect(queue.paths, [] as [String])
}

private func waitsUntilRecordingStops() {
    var queue = TitlePromptQueue()
    queue.add("/tmp/a")
    let recording = TitlePrompt(appActive: true, recording: true, preparing: false, resetting: false, askingReset: false)
    let preparing = TitlePrompt(appActive: true, recording: false, preparing: true, resetting: false, askingReset: false)
    let resetting = TitlePrompt(appActive: true, recording: false, preparing: false, resetting: true, askingReset: false)
    let asking = TitlePrompt(appActive: true, recording: false, preparing: false, resetting: false, askingReset: true)
    expect(queue.next(when: recording), nil)
    expect(queue.next(when: preparing), nil)
    expect(queue.next(when: resetting), nil)
    expect(queue.next(when: asking), nil)
    expect(queue.paths, ["/tmp/a"])
}

private func asksInStopOrder() {
    var queue = TitlePromptQueue()
    queue.add("/tmp/a")
    queue.add("/tmp/b")
    let idle = TitlePrompt(appActive: true, recording: false, preparing: false, resetting: false, askingReset: false)
    expect(queue.next(when: idle), "/tmp/a")
    expect(queue.next(when: idle), "/tmp/b")
    expect(queue.next(when: idle), nil)
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    guard actual == expected else {
        fputs("expected \(expected)\nactual   \(actual)\n", stderr)
        exit(1)
    }
}
