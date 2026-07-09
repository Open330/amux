import Foundation

/// Bounded off-main writer for the SSH control client's stdin pipe.
///
/// `RemoteTmuxControlConnection` records command FIFO entries on the main actor
/// before this writer can emit bytes, so tmux `%begin`/`%end` replies cannot
/// outrun their local correlation slot. The write itself may block on a stalled
/// SSH pipe; keeping it on this serial queue prevents that from freezing UI.
@MainActor
final class RemoteTmuxControlPipeWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let onFailure: @MainActor @Sendable () -> Void
    private var closed = false
    private var pendingBytes = 0

    init(
        handle: FileHandle,
        label: String,
        maxPendingBytes: Int,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = maxPendingBytes
        self.onFailure = onFailure
    }

    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard !closed,
              data.count <= maxPendingBytes - pendingBytes else {
            return false
        }
        pendingBytes += data.count

        queue.async { [weak self, handle, data] in
            var didFail = false
            do {
                try handle.write(contentsOf: data)
            } catch {
                didFail = true
            }
            Task { @MainActor [weak self] in
                self?.finishWrite(byteCount: data.count, didFail: didFail)
            }
        }
        return true
    }

    /// Suspends until `byteCount` bytes fit in the pending budget (or returns
    /// immediately when they already do). Returns `false` once the writer is
    /// closed. Lets a bulk sender (chunked paste) pace itself to the pipe's
    /// drain rate instead of tripping the bounded `enqueue` rejection — which
    /// the connection treats as a transport failure and answers with a
    /// reconnect.
    func waitForCapacity(_ byteCount: Int) async -> Bool {
        guard !closed else { return false }
        if byteCount <= maxPendingBytes - pendingBytes { return true }
        return await withCheckedContinuation { continuation in
            capacityWaiters.append((byteCount, continuation))
        }
    }

    private var capacityWaiters: [(byteCount: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    private func resumeSatisfiedCapacityWaiters() {
        while let next = capacityWaiters.first,
              closed || next.byteCount <= maxPendingBytes - pendingBytes {
            capacityWaiters.removeFirst()
            next.continuation.resume(returning: !closed)
        }
    }

    private func finishWrite(byteCount: Int, didFail: Bool) {
        pendingBytes = max(0, pendingBytes - byteCount)
        if didFail, !closed {
            onFailure()
        }
        resumeSatisfiedCapacityWaiters()
    }

    func close() {
        guard !closed else { return }
        closed = true
        queue.async { [handle] in
            try? handle.close()
        }
        resumeSatisfiedCapacityWaiters()
    }
}
