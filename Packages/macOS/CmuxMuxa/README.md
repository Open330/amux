# CmuxMuxa

Async Swift client for the [muxa](https://github.com/open330/muxa) daemon's
line-delimited-JSON unix-socket protocol. This is the agent-state layer of the
amux integration: muxad correlates Claude Code / Codex / Gemini CLI hook
events with tmux panes and sessions; this package surfaces that registry to
the app as values and an `AsyncThrowingStream`.

## Usage

```swift
import CmuxMuxa

let client = MuxaClient()                     // default muxad socket path
let hello = try await client.hello()          // capability negotiation (pins protocol v2)
let agents = try await client.snapshot()      // all tracked agents
let blocked = agents.filter { $0.state.needsAttention }

for try await transition in try await client.transitions() {
    updateBadge(pane: transition.agent.pane, state: transition.to)
}
```

The client pins protocol v2 via `hello`, so newer daemons (v3+) serve it
through muxad's negotiated-downgrade path. Enum decoding is lenient: unknown
`state` / `kind` strings become `.unknown(raw)` instead of failing the payload.

## Recovery model

- Request/response calls share one lazily opened connection; any transport or
  framing error drops it and the next call reconnects.
- `transitions()` uses a dedicated connection. The stream finishing (daemon
  EOF/restart) is the signal to re-`snapshot()` and resubscribe — the same
  reconcile muxad's own lagged-subscriber path expects.

## Testing

Every seam is constructor-injected. Point the client at a `FakeMuxaDaemon`
(see `Tests/CmuxMuxaTests/FakeMuxaDaemon.swift`), a scripted daemon bound to a
temporary socket path:

```swift
let daemon = try FakeMuxaDaemon { requestLine in [cannedResponse(for: requestLine)] }
defer { daemon.shutdown() }
let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
```

`MuxaSocketAddress.defaultPath(environment:uid:)` takes its environment and
uid as parameters for the same reason.
