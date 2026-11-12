import Foundation

@main
enum SpeakerTest {
    static func main() {
        checkMeet()
        checkTeams()
        checkAssign()
        checkLine()
    }
}

private func checkMeet() {
    let tree = CaptionNode(role: "AXGroup", title: "字幕", children: [
        CaptionNode(role: "AXGroup", classes: "nMcdL", children: [
            CaptionNode(role: "AXGroup", classes: "KcIKyf jxFHg", children: [
                CaptionNode(role: "AXStaticText", value: "あなた"),
            ]),
            CaptionNode(role: "AXGroup", classes: "ygicle", children: [
                CaptionNode(role: "AXStaticText", value: "本文は使わない"),
            ]),
        ]),
        CaptionNode(role: "AXGroup", classes: "nMcdL", children: [
            CaptionNode(role: "AXGroup", classes: "KcIKyf", children: [
                CaptionNode(role: "AXStaticText", value: "kohki nakamura"),
            ]),
        ]),
    ])
    let sample = CaptionRead.sample(in: [tree])
    expect(sample.speaker, "kohki nakamura")
    expect(sample.localName, "あなた")
}

private func checkTeams() {
    let tree = CaptionNode(role: "AXWindow", children: [
        CaptionNode(role: "AXImage", title: "自分のビデオ, 中村 光毅, ミュート解除, コンテキスト メニューあり"),
        CaptionNode(role: "AXGroup", title: "ライブ キャプション", children: [
            CaptionNode(role: "AXGroup", children: [
                CaptionNode(role: "AXStaticText", value: "test"),
                CaptionNode(role: "AXGroup", title: "未確認"),
                CaptionNode(role: "AXStaticText", value: "本文A"),
            ]),
            CaptionNode(role: "AXGroup", children: [
                CaptionNode(role: "AXStaticText", value: "中村 光毅"),
                CaptionNode(role: "AXStaticText", value: "本文B"),
            ]),
        ]),
    ])
    let sample = CaptionRead.sample(in: [tree])
    expect(sample.speaker, "中村 光毅")
    expect(sample.localName, "中村 光毅")
    let remote = SpeakerAssign.remoteLabel(
        start: 5,
        end: 8,
        marks: [
            SpeakerMark(time: 1, name: "中村 光毅"),
            SpeakerMark(time: 5, name: "test"),
        ],
        localNames: ["あなた", "中村 光毅"],
        until: 10
    )
    expect(remote, "test")
}

private func checkAssign() {
    let marks = [
        SpeakerMark(time: 1, name: "あなた"),
        SpeakerMark(time: 5, name: "kohki nakamura"),
        SpeakerMark(time: 9, name: ""),
    ]
    expect(SpeakerAssign.remoteLabel(start: 5.2, end: 8, marks: marks, localNames: ["あなた"], until: 12), "kohki nakamura")
    expect(SpeakerAssign.remoteLabel(start: 1.2, end: 4, marks: marks, localNames: ["あなた"], until: 12), nil)
    expect(SpeakerAssign.remoteLabel(start: 0, end: 0.8, marks: marks, localNames: ["あなた"], until: 12), nil)
    expect(SpeakerAssign.remoteLabel(start: 9.2, end: 11, marks: marks, localNames: ["あなた"], until: 12), nil)
}

private func checkLine() {
    let own = TranscriptLine("[15:31:10] 自分 はい")
    expect(own?.label, "自分")
    expect(own?.text, "はい")
    let named = TranscriptLine("[15:31:12] 中村 光毅\t今週の定例です")
    expect(named?.label, "中村 光毅")
    expect(named?.text, "今週の定例です")
}

private func expect<T: Equatable>(_ actual: T, _ expected: T) {
    if actual == expected { return }
    fputs("expected \(expected), got \(actual)\n", stderr)
    exit(1)
}
