import Foundation

/// 画面に出す字幕の世代。
/// 停止したあとの文字は残す。ユーザーが開始した次の録音では、取り込みが成功するまで更新を溜め、成功したら空にしてから出す。失敗した開始では溜めた更新を捨て、前の画面を残す。
final class DisplayGate: @unchecked Sendable {
    enum Piece: Equatable, Sendable {
        case line(String)
        case system(String)
        case microphone(String)
        case notice(String)
    }

    enum Intake: Equatable, Sendable {
        case show(Int)
        case held
    }

    struct Release: Equatable, Sendable {
        var generation: Int
        var pending: [Piece]
    }

    private let lock = NSLock()
    private var generation = 0
    private var holding = false
    private var pending: [Piece] = []

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// 進行中の表示を無効にする。リセットで使う。
    func bump() {
        lock.lock()
        generation += 1
        holding = false
        pending.removeAll()
        lock.unlock()
    }

    /// ユーザーが録音を始める直前。前の画面はそのまま、新しい更新は成功まで出さない。
    func hold() {
        lock.lock()
        generation += 1
        holding = true
        pending.removeAll()
        lock.unlock()
    }

    func intake(_ piece: Piece) -> Intake {
        lock.lock()
        defer { lock.unlock() }
        if holding {
            pending.append(piece)
            return .held
        }
        return .show(generation)
    }

    /// 取り込みが始まった。呼び出し側は画面を空にしてから `pending` を出す。
    func release() -> Release? {
        lock.lock()
        defer { lock.unlock() }
        guard holding else { return nil }
        holding = false
        let release = Release(generation: generation, pending: pending)
        pending.removeAll()
        return release
    }

    /// 録音が始まらなかった。前の画面を残す。
    func cancel() {
        lock.lock()
        guard holding else {
            lock.unlock()
            return
        }
        generation += 1
        holding = false
        pending.removeAll()
        lock.unlock()
    }
}
