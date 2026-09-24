import Foundation

/// Serial, off-actor writer for one child process's stdin.
///
/// `FileHandle.write(contentsOf:)` blocks once the pipe buffer fills (macOS default ~64 KB). A
/// `session/prompt` frame carrying a large context exceeds that, and if the agent stops reading —
/// busy, or wedged — an inline write would block whichever thread made it. Writing from the
/// `ACPClient` actor would therefore freeze its reader and every timeout watchdog with it, turning a
/// slow agent into a deadlocked client with no diagnostic.
///
/// This type keeps that blocking write on its own queue, so the actor only ever enqueues.
final class ACPFrameWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tonycast.hermes.acp-writer")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pendingChunks: [Data] = []
    /// Set on stop so a write that lands after teardown is dropped instead of trapping.
    private var isStopped = true

    func start(handle: FileHandle) {
        lock.lock()
        self.handle = handle
        isStopped = false
        pendingChunks.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        lock.lock()
        guard !isStopped, handle != nil else {
            lock.unlock()
            return
        }
        // Bounded: an unread agent must not let the queue grow without limit. Dropping the oldest
        // frames is safe — a client that far behind is already failing its own timeouts.
        pendingChunks.append(data)
        if pendingChunks.count > Self.maximumPendingChunks {
            pendingChunks.removeFirst(pendingChunks.count - Self.maximumPendingChunks)
        }
        lock.unlock()

        queue.async { [weak self] in self?.drain() }
    }

    func stop() {
        lock.lock()
        isStopped = true
        handle = nil
        pendingChunks.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !isStopped, let handle, !pendingChunks.isEmpty else {
                lock.unlock()
                return
            }
            let chunk = pendingChunks.removeFirst()
            lock.unlock()
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                // The child is gone; the client learns through its own exit handling.
                return
            }
        }
    }

    private static let maximumPendingChunks = 256
}
