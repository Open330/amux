import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ControlledAmuxSessionSwitcherLoader: AmuxSessionSwitcherLoading {
    private let requestStream: AsyncStream<RemoteTmuxHost>
    private let requestContinuation: AsyncStream<RemoteTmuxHost>.Continuation
    private var pending: [String: [CheckedContinuation<[AmuxSessionSwitcherItem], any Error>]] = [:]

    init() {
        let pair = AsyncStream.makeStream(of: RemoteTmuxHost.self)
        requestStream = pair.stream
        requestContinuation = pair.continuation
    }

    func requests() -> AsyncStream<RemoteTmuxHost> {
        requestStream
    }

    func load(host: RemoteTmuxHost) async throws -> [AmuxSessionSwitcherItem] {
        requestContinuation.yield(host)
        return try await withCheckedThrowingContinuation { continuation in
            pending[host.id, default: []].append(continuation)
        }
    }

    func succeed(_ host: RemoteTmuxHost, items: [AmuxSessionSwitcherItem]) {
        resume(host, with: .success(items))
    }

    func fail(_ host: RemoteTmuxHost) {
        resume(host, with: .failure(TestFailure()))
    }

    private func resume(
        _ host: RemoteTmuxHost,
        with result: Result<[AmuxSessionSwitcherItem], any Error>
    ) {
        guard var continuations = pending[host.id], !continuations.isEmpty else {
            preconditionFailure("No pending load for \(host.destination)")
        }
        let continuation = continuations.removeFirst()
        pending[host.id] = continuations.isEmpty ? nil : continuations
        continuation.resume(with: result)
    }

    private struct TestFailure: Error {}
}
