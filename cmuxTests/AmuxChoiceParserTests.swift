import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmuxChoiceParserTests: XCTestCase {
    func testParsesDottedMenu() {
        let text = """
        Which approach do you want?

          1. Rewrite the module
          2. Patch in place
          3. Skip for now

        ❯
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices, [
            .init(number: 1, label: "Rewrite the module"),
            .init(number: 2, label: "Patch in place"),
            .init(number: 3, label: "Skip for now"),
        ])
    }

    func testToleratesSelectionCaretAndBoxDrawing() {
        let text = """
        │ ❯ 1) Yes, proceed
        │   2) No, cancel
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.map(\.number), [1, 2])
        XCTAssertEqual(choices.first?.label, "Yes, proceed")
    }

    func testRedrawnMenuKeepsLastOccurrencePerNumber() {
        // A menu that scrolled once then redrew appears twice; the later
        // (bottom) copy wins.
        let text = """
        1. old label
        2. two
        1. new label
        2. two
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.first(where: { $0.number == 1 })?.label, "new label")
    }

    func testRejectsNonContiguousNumbering() {
        // Stray "1." / "3." prose lines are not a clean 1..n menu.
        XCTAssertTrue(AmuxChoiceParser.parse("1. first\n3. third").isEmpty)
    }

    func testRejectsSingleNumberedLine() {
        // One "1. " line is almost always prose, not a menu.
        XCTAssertTrue(AmuxChoiceParser.parse("1. just one item").isEmpty)
    }

    func testEmptyOnPlainText() {
        XCTAssertTrue(AmuxChoiceParser.parse("no menu here\njust output\n").isEmpty)
    }

    // D-F1: a boxed TUI menu's right border/padding must not bleed into labels.
    func testStripsBoxRightBorderAndPaddingFromLabels() {
        let text = """
        ┌────────────────────────────┐
        │ ❯ 1. Yes                    │
        │   2. No                     │
        └────────────────────────────┘
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.map(\.number), [1, 2])
        XCTAssertEqual(choices.map(\.label), ["Yes", "No"])
    }

    // D-F2: a 0-numbered option (commonly Cancel/Quit/Back) must survive and be
    // surfaced when the menu is a clean 0..n run.
    func testIncludesZeroNumberedOption() {
        let text = """
        0. Cancel
        1. Keep going
        2. Undo
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.map(\.number), [0, 1, 2])
        XCTAssertEqual(choices.first?.label, "Cancel")
    }

    // D-F3: the caret-highlighted option is recorded as the default so the
    // sheet's default button matches what the TUI highlighted.
    func testCaretHighlightedOptionIsDefault() {
        let text = """
        1. A
        ❯ 2. B
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.map(\.number), [1, 2])
        XCTAssertEqual(choices.filter(\.isDefault).map(\.number), [2])
    }

    func testNoCaretLeavesNoDefault() {
        let text = """
        1. A
        2. B
        """
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertFalse(choices.contains(where: \.isDefault))
    }

    func testCaretPrecededByNonAsciiWhitespaceIsDetected() {
        // A stray non-ASCII whitespace (NBSP, U+00A0) before the caret still
        // matches linePattern's `\s*`; the caret scan must skip the same
        // whitespace class so the highlight isn't missed.
        let text = "1. A\n\u{00A0}❯ 2. B"
        let choices = AmuxChoiceParser.parse(text)
        XCTAssertEqual(choices.map(\.number), [1, 2])
        XCTAssertEqual(choices.filter(\.isDefault).map(\.number), [2])
    }
}
