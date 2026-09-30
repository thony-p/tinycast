import Foundation

/// Serial, off-actor writer for one child process's stdin.
///
/// `FileHandle.write(contentsOf:)` blocks once the pipe buffer fills (macOS default ~64 KB). A
/// `session/prompt` frame carrying a large context exceeds that, and if the agent stops reading —
/// busy, or wedged — an inline write would block whichever thread made it. Writing from the
/// `ACPClient` actor would therefore freeze its reader and every timeout watchdog with it, turning a
/// slow agent into a deadlocked client with no diagnostic.
///
/// This type keeps that blocking write on its own queue, so the actor only ever enqueues. Teardown
/// runs on that same queue, so a write already in flight finishes before the handle is dropped and
/// no write can land in a file descriptor the OS has since reused.
final class ACPFrameWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tonycast.hermes.acp-writer")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pendingChunks: [Data] = []
    private var pendingBytes = 0
    /// Set on stop so a write that lands after teardown is dropped instead of trapping.
    private var isStopped = true
    /// Set when the byte bound was reached, so later frames are refused rather than queued.
    private var isOverflowed = false

    func start(handle: FileHandle) {
        lock.lock()
        self.handle = handle
        isStopped = false
        isOverflowed = false
        pendingChunks.removeAll(keepingCapacity: false)
        pendingBytes = 0
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        lock.lock()
        guard !isStopped, !isOverflowed, handle != nil else {
            lock.unlock()
            return
        }
        // Bounded by bytes, not frame count: a single prompt frame can be megabytes, so a count
        // limit lets an unread agent grow memory without limit. Refusing new frames is the only
        // safe response — dropping one already queued would corrupt the framed stream it belongs to.
        pendingBytes += data.count
        pendingChunks.append(data)
        if pendingBytes > Self.maximumPendingBytes {
            isOverflowed = true
            pendingChunks.removeAll(keepingCapacity: false)
            pendingBytes = 0
        }
        lock.unlock()

        queue.async { [weak self] in self?.drain() }
    }

    /// Stops accepting frames and drops the queue, on the writer's own queue so the teardown is
    /// ordered after any write already running.
    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handle = nil
            self.pendingChunks.removeAll(keepingCapacity: false)
            self.pendingBytes = 0
            self.lock.unlock()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !isStopped, !isOverflowed, let handle, !pendingChunks.isEmpty else {
                lock.unlock()
                return
            }
            let chunk = pendingChunks.removeFirst()
            pendingBytes -= chunk.count
            lock.unlock()
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                // The child is gone; the client learns through its own exit handling. Stop cleanly
                // rather than retrying a dead handle on every later enqueue.
                lock.lock()
                isStopped = true
                pendingChunks.removeAll(keepingCapacity: false)
                pendingBytes = 0
                lock.unlock()
                return
            }
        }
    }

    private static let maximumPendingBytes = 4 * 1_048_576
}
