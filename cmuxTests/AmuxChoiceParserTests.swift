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
}
