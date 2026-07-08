import Foundation

/// Extracts a numbered menu (e.g. Claude Code's `AskUserQuestion` /
/// `ExitPlanMode`, or a Codex/Gemini selection prompt) from a tmux pane's
/// captured visible text, so amux can promote it to a native choice sheet.
///
/// muxad reports the `waiting_choice` state but not the options themselves —
/// they only exist as rendered terminal text — so this is a best-effort
/// screen parse. Callers fall back to a free-text prompt when it finds
/// nothing (``parse(_:)`` returns an empty array).
enum AmuxChoiceParser {
    /// One parsed menu option.
    struct Choice: Equatable {
        /// The number the user types to pick this option.
        let number: Int
        /// The option's visible label (trimmed, selection caret removed).
        let label: String
    }

    /// Matches a numbered option line, tolerating a leading selection caret
    /// (`❯`, `>`, `*`, `•`) and box-drawing padding, and `1.` / `1)` / `1:`
    /// number punctuation. Anchored per line via `parse(_:)`.
    private static let linePattern = /^\s*[│┃|]?\s*[❯>*•]?\s*(\d{1,3})[.):]\s+(\S.*?)\s*$/

    /// Parses the numbered options from `paneText` (a `capture-pane -p`
    /// snapshot), newest screen wins. Deduplicates by number keeping the
    /// last occurrence (a redrawn menu appears twice in scrollback), and
    /// returns them in ascending numeric order. Empty when no menu is found
    /// or the numbering isn't a clean `1..n` run starting at 1 — which keeps
    /// stray "1. " prose lines from being mistaken for a menu.
    static func parse(_ paneText: String) -> [Choice] {
        var byNumber: [Int: String] = [:]
        for line in paneText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = String(line).wholeMatch(of: linePattern) else { continue }
            let number = Int(match.1) ?? -1
            let label = String(match.2).trimmingCharacters(in: .whitespaces)
            guard number > 0, !label.isEmpty else { continue }
            byNumber[number] = label
        }
        let numbers = byNumber.keys.sorted()
        guard numbers.count >= 2, numbers == Array(1...numbers.count) else { return [] }
        return numbers.map { Choice(number: $0, label: byNumber[$0]!) }
    }
}
