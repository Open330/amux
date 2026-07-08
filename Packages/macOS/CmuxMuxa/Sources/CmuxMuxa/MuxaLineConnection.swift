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

    /// Connects to the unix socket at `path`.
    ///
    /// - Throws: ``MuxaClientError/socketUnavailable(path:errno:)`` when the
    ///   socket cannot be created or connected (daemon not running).
    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MuxaClientError.socketUnavailable(path: path, errno: Foundation.errno)
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
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let connectErrno = Foundation.errno
            Darwin.close(fd)
            throw MuxaClientError.socketUnavailable(path: path, errno: connectErrno)
        }

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
    func receiveLine() async throws -> Data? {
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
        guard count > 0 else {
            // EOF (0) or a hard read error (<0): end-of-stream for readers.
            finishOnQueue()
            return
        }
        pending.append(contentsOf: scratch[0..<count])
        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newlineIndex])
            pending.removeSubrange(pending.startIndex...newlineIndex)
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
