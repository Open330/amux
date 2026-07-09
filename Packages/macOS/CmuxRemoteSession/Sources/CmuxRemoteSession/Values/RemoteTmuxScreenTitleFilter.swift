public import Foundation

/// Strips the GNU screen / tmux window-title escape (`ESC k <title> ESC \`) from a
/// mirrored pane's output stream.
///
/// A remote shell running *inside* tmux sees `TERM=screen*`/`tmux*`, so its prompt
/// (e.g. oh-my-zsh) sets the title with the screen sequence `\ek<cmd>\e\\` instead of
/// the xterm OSC. `%output` is the raw pty copy, so tmux forwards the `ESC k` bytes
/// verbatim and only interprets them for its OWN screen (window name) — its rendered
/// pane (`capture-pane`) has the title stripped. cmux's mirror surface is an
/// xterm-style emulator that doesn't recognize `ESC k`, so it would instead print the
/// title text onto the screen — e.g. `echo "ej"\r\n\ekecho\e\\ej` renders as `echoej`.
/// To match what the remote tmux actually shows, the mirror interprets/strips the
/// sequence here (the tab name already tracks tmux's `window_name`).
///
/// Stateful across calls: a `%output` chunk can split the sequence at any byte. Like
/// tmux/screen, `ESC k` is terminated ONLY by ST (`ESC \`), so an unterminated title
/// consumes until ST — matching tmux's own screen exactly (verified empirically by
/// diffing cmux's render against `capture-pane`).
public struct RemoteTmuxScreenTitleFilter {
    private var state: RemoteTmuxScreenTitleFilterState = .text

    /// Creates a filter with no buffered escape-sequence state.
    public init() {}

    /// Returns `data` with any `ESC k … ESC \` title sequences removed.
    public mutating func filter(_ data: Data) -> Data {
        // Hot path: routeOutput calls this for every %output chunk, and TUI/colored
        // output contains ESC in essentially every chunk — so "no ESC at all" is a
        // useless fast path there. Return unchanged unless the chunk contains an
        // actual `ESC k` introducer or ends on a lone ESC (the `k` could arrive in
        // the next chunk); everything else passes through the state machine
        // unchanged anyway, so skipping the per-byte copy is behavior-identical.
        if state == .text, !Self.mayContainTitleIntroducer(data) { return data }
        // Build into a `[UInt8]` buffer (cheaper than per-byte `Data.append`) and wrap
        // it once at the end.
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b {
                    state = .esc           // hold the ESC; emit it only if it isn't `ESC k`
                } else {
                    out.append(byte)
                }
            case .esc:
                if byte == UInt8(ascii: "k") {
                    state = .title         // `ESC k` → start of title; drop both bytes
                } else {
                    out.append(0x1b)       // not a title: emit the held ESC …
                    if byte == 0x1b {
                        // another ESC: keep holding it (stay in .esc)
                    } else {
                        out.append(byte)   // … followed by this byte
                        state = .text
                    }
                }
            case .title:
                // tmux/screen terminate `ESC k` ONLY on ST (`ESC \`), never on BEL —
                // so a BEL is part of the title and the title runs until ST (matching
                // what the remote tmux renders). Drop everything until then.
                if byte == 0x1b {
                    state = .titleEsc      // maybe the `ESC \` terminator
                }
                // otherwise (incl. BEL): title text — drop it
            case .titleEsc:
                if byte == 0x5c {
                    state = .text          // `ESC \` (ST) terminates the title
                } else if byte == 0x1b {
                    state = .titleEsc      // consecutive ESC — keep waiting
                } else {
                    state = .title         // ESC + other byte: still inside the title
                }
            }
        }
        return Data(out)
    }

    /// `true` when `data` contains `ESC k` (a title start) or ends with a lone
    /// ESC whose follow-up byte hasn't arrived yet. `false` guarantees the state
    /// machine would emit `data` unchanged from the `.text` state.
    private static func mayContainTitleIntroducer(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let count = raw.count
            var offset = 0
            while offset < count {
                guard let found = memchr(base + offset, 0x1b, count - offset) else { return false }
                let index = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                if index == count - 1 { return true } // chunk ends mid-sequence
                if base[index + 1] == UInt8(ascii: "k") { return true }
                offset = index + 1
            }
            return false
        }
    }
}
