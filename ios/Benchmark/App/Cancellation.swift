import Foundation

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var action: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() {
        lock.lock(); stopped = true; let current = action; lock.unlock()
        current?()
    }
    func install(_ callback: (() -> Void)?) {
        lock.lock(); action = callback; let invoke = stopped; lock.unlock()
        if invoke { callback?() }
    }
    func check() throws { if isCancelled { throw CancellationError() } }
}

