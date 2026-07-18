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
        /// The option's visible label (trailing whitespace and box-drawing
        /// border glyphs trimmed, selection caret removed).
        let label: String
        /// Whether the TUI drew its selection caret (`❯`/`>`/`*`/`•`) on this
        /// option — the option the terminal itself highlighted as the default.
        var isDefault: Bool = false
    }

    /// Matches a numbered option line, tolerating a leading selection caret
    /// (`❯`, `>`, `*`, `•`) and box-drawing padding, and `1.` / `1)` / `1:`
    /// number punctuation. Group 1 is the number, group 2 the label. The caret
    /// stays NON-capturing here: wrapping it in a capture group fails the Swift
    /// regex-literal lexer, so ``lineHasSelectionCaret(_:)`` detects it
    /// separately. Anchored per line via `parse(_:)`.
    private static let linePattern = /^\s*[│┃|]?\s*[❯>*•]?\s*(\d{1,3})[.):]\s+(\S.*?)\s*$/

    /// The selection-caret glyphs a TUI draws on the highlighted option.
    private static let caretScalars: Set<Unicode.Scalar> = ["❯", ">", "*", "•"]

    /// Whitespace plus box-drawing border glyphs (U+2500–U+257F) and the ASCII
    /// pipe, trimmed off the trailing edge of a captured label so a boxed TUI
    /// menu's right border/padding (e.g. `Yes   │`) doesn't bleed into it.
    private static let labelTrailingTrim: CharacterSet = {
        var set = CharacterSet.whitespaces
        let boxDrawingStart: Unicode.Scalar = "\u{2500}"
        let boxDrawingEnd: Unicode.Scalar = "\u{257F}"
        set.insert(charactersIn: boxDrawingStart...boxDrawingEnd)
        set.insert(charactersIn: "|")
        return set
    }()

    /// Parses the numbered options from `paneText` (a `capture-pane -p`
    /// snapshot), newest screen wins. Deduplicates by number keeping the
    /// last occurrence (a redrawn menu appears twice in scrollback), and
    /// returns them in ascending numeric order. Also records which option
    /// carries the selection caret so callers can default to it. Empty when no
    /// menu is found or the numbering isn't a clean contiguous run anchored at
    /// 0 or 1 — which keeps stray "1. " prose lines from being mistaken for a
    /// menu.
    static func parse(_ paneText: String) -> [Choice] {
        var byNumber: [Int: (label: String, isDefault: Bool)] = [:]
        for line in paneText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = String(line).wholeMatch(of: linePattern) else { continue }
            let number = Int(match.1) ?? -1
            let label = trimmedLabel(String(match.2))
            let isDefault = lineHasSelectionCaret(line)
            guard number >= 0, !label.isEmpty else { continue }
            byNumber[number] = (label, isDefault)
        }
        let numbers = byNumber.keys.sorted()
        // A real menu is a clean contiguous run anchored at 1 (agents number
        // from 1) or at 0 (Cancel/Quit/Back is commonly option 0). A run that
        // is gapped, or not anchored at 0/1, is stray "1." prose rather than a
        // menu — leave it to the free-text fallback.
        guard let lo = numbers.first, let hi = numbers.last,
              numbers.count >= 2, lo == 0 || lo == 1,
              numbers == Array(lo...hi)
        else { return [] }
        return numbers.compactMap { number in
            byNumber[number].map { entry in
                Choice(number: number, label: entry.label, isDefault: entry.isDefault)
            }
        }
    }

    /// Strips trailing whitespace and box-drawing border glyphs from a captured
    /// label. Leading padding is consumed by ``linePattern``, but a boxed
    /// menu's right border (`… │`) lands inside the lazy label capture, so drop
    /// it from the trailing edge only (a legitimate label never ends in one).
    private static func trimmedLabel(_ raw: String) -> String {
        let scalars = raw.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let previous = scalars.index(before: end)
            guard labelTrailingTrim.contains(scalars[previous]) else { break }
            end = previous
        }
        return String(scalars[scalars.startIndex..<end])
    }

    /// Whether `line` (already matched by ``linePattern``) carries a selection
    /// caret before its number: skip the optional leading whitespace and box
    /// border, then the first content scalar is the caret iff the TUI
    /// highlighted this option. Detected here rather than in the regex because
    /// a capturing caret group fails the Swift regex-literal lexer.
    private static func lineHasSelectionCaret<S: StringProtocol>(_ line: S) -> Bool {
        for scalar in line.unicodeScalars {
            if scalar == " " || scalar == "\t" { continue }
            if scalar == "│" || scalar == "┃" || scalar == "|" { continue }
            return caretScalars.contains(scalar)
        }
        return false
    }
}
