import Foundation

/// A line-delimited-JSON connection to a unix-domain socket.
///
/// Owns the socket fd, a `DispatchSource` read source (the sanctioned
/// low-level socket I/O primitive — there is no async-native replacement),
/// and the newline framing. Callers use ``send(line:)`` and await
/// ``receiveLine()``; nothing else about the fd leaks out.
///
/// Every mutation of the buffers, waiter FIFO, and source lifecycle happens
/// on `queue`, which is the safety argument for `@unchecked Sendable`.
final class MuxaLineConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let readSource: any DispatchSourceRead
    /// Partial-line accumulator; queue-confined.
    private var pending = Data()
    /// Complete lines not yet handed to a waiter; queue-confined.
    private var bufferedLines: [Data] = []
    /// FIFO of readers awaiting a line; queue-confined. Resumed with `nil`
    /// on EOF/close so consumers see a clean end-of-stream.
    private var waiters: [CheckedContinuation<Data?, any Error>] = []
    /// Set on `queue` when EOF was seen or ``close()`` ran.
    private var finished = false
    /// Upper bound on the partial-line accumulator. A daemon that streams
    /// bytes without a newline must not grow this without limit; hitting the
    /// cap ends the stream rather than exhausting memory.
    private static let maxPendingBytes = 8 * 1_048_576
    /// `SO_SNDTIMEO` for the blocking `write` in ``send(line:)``.
    private static let sendTimeoutSeconds: Int = 5
    /// Bounded wait for a non-blocking `connect` to complete.
    private static let connectTimeoutMilliseconds: Int32 = 3000

    /// Connects to the unix socket at `path`.
    ///
    /// - Throws: ``MuxaClientError/socketUnavailable(path:errno:)`` when the
    ///   socket cannot be created or connected (daemon not running).
    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MuxaClientError.socketUnavailable(path: path, errno: Foundation.errno)
        }
        // Never let a write to a peer-closed socket raise SIGPIPE (which would
        // terminate the whole app); surface it as an `EPIPE` error instead, so
        // `send(line:)` maps it to `.connectionClosed`. Mirrors the CLI socket
        // setup (`CMUXCLI+SIGPIPEProbes.swift`).
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        // Bound `write`: `send(line:)` runs a blocking `write` from the client
        // actor, so a daemon that stops draining its receive buffer would
        // otherwise stall the actor indefinitely. With `SO_SNDTIMEO` the write
        // fails with `EAGAIN` after the timeout, which `send` maps to
        // `.connectionClosed`.
        var sendTimeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
        _ = withUnsafePointer(to: &sendTimeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw MuxaClientError.socketUnavailable(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dest.count)))
            }
        }
        // Connect non-blocking with a bounded wait: a blocking `connect` runs
        // from the client actor, so a saturated listener backlog would stall
        // it. On the common paths this still returns immediately — success, or
        // `ENOENT`/`ECONNREFUSED` when no daemon is listening.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) }
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            let immediateErrno = Foundation.errno
            if immediateErrno == EINPROGRESS {
                // Connection is establishing: wait (bounded) for writability.
                var pollDescriptor = pollfd(fd: fd, events: Int16(truncatingIfNeeded: POLLOUT), revents: 0)
                let ready = poll(&pollDescriptor, 1, Self.connectTimeoutMilliseconds)
                if ready <= 0 {
                    Darwin.close(fd)
                    throw MuxaClientError.socketUnavailable(path: path, errno: ready == 0 ? ETIMEDOUT : Foundation.errno)
                }
                var soError: Int32 = 0
                var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength)
                guard soError == 0 else {
                    Darwin.close(fd)
                    throw MuxaClientError.socketUnavailable(path: path, errno: soError)
                }
            } else {
                Darwin.close(fd)
                throw MuxaClientError.socketUnavailable(path: path, errno: immediateErrno)
            }
        }
        // Restore blocking mode: reads are driven by the DispatchSource and
        // writes rely on `SO_SNDTIMEO`, both of which expect a blocking fd.
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) }

        self.fd = fd
        self.queue = DispatchQueue(label: "com.cmux.muxa.line-connection")
        self.readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainReadable()
        }
        readSource.setCancelHandler {
            Darwin.close(fd)
        }
        readSource.resume()
    }

    /// Writes one JSON line (a `\n` terminator is appended).
    ///
    /// - Throws: ``MuxaClientError/connectionClosed`` when the peer has gone
    ///   away.
    func send(line: Data) throws {
        var payload = line
        payload.append(UInt8(ascii: "\n"))
        var written = 0
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while written < raw.count {
                let result = write(fd, raw.baseAddress! + written, raw.count - written)
                if result < 0 {
                    if Foundation.errno == EINTR { continue }
                    throw MuxaClientError.connectionClosed
                }
                written += result
            }
        }
    }

    /// The next complete line (without its `\n`), or `nil` on EOF/close.
    ///
    /// Callers must not overlap calls; the client actor (and the single
    /// subscribe pump) serialize access by construction.
    ///
    /// Honors task cancellation: a cancelled awaiter closes the connection,
    /// which resumes the pending waiter with `nil`. Without this a wedged
    /// daemon (accepts but never replies) would suspend the caller — and its
    /// enclosing `Task` — forever, since a bare `withCheckedContinuation` does
    /// not observe cancellation.
    func receiveLine() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if !bufferedLines.isEmpty {
                        continuation.resume(returning: bufferedLines.removeFirst())
                    } else if finished {
                        continuation.resume(returning: nil)
                    } else {
                        waiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            close()
        }
    }

    /// Tears the connection down; pending and future readers get `nil`.
    /// Safe to call more than once.
    func close() {
        queue.async { [self] in
            finishOnQueue()
        }
    }

    deinit {
        // The cancel handler owns the fd close; cancelling here covers the
        // "owner dropped the connection without calling close()" path.
        if !readSource.isCancelled {
            readSource.cancel()
        }
    }

    /// Runs on `queue`: pulls available bytes, resolves waiters/buffers lines.
    private func drainReadable() {
        guard !finished else { return }
        var scratch = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &scratch, scratch.count)
        if count < 0 {
            // A transient interruption is not end-of-stream: the source will
            // fire again. Only a genuine EOF (0) or a hard error tears down.
            let err = Foundation.errno
            if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { return }
            finishOnQueue()
            return
        }
        guard count > 0 else {
            // EOF: the peer closed its write end.
            finishOnQueue()
            return
        }
        pending.append(contentsOf: scratch[0..<count])
        if pending.count > Self.maxPendingBytes {
            // A line longer than the cap means the peer is not framing with
            // newlines; refuse to buffer unbounded and end the stream.
            finishOnQueue()
            return
        }
        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newlineIndex])
            pending.removeSubrange(pending.startIndex...newlineIndex)
            // Skip blank lines: an empty line is never a valid JSON message, so
            // a daemon keepalive newline must not surface as a decode failure.
            if line.isEmpty { continue }
            if waiters.isEmpty {
                bufferedLines.append(line)
            } else {
                waiters.removeFirst().resume(returning: line)
            }
        }
    }

    /// Runs on `queue`: marks the connection finished exactly once, resumes
    /// every waiter with `nil`, and cancels the read source.
    private func finishOnQueue() {
        guard !finished else { return }
        finished = true
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
        readSource.cancel()
    }
}
