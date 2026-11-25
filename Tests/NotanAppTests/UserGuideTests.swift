import XCTest

@testable import NotanUI

final class UserGuideTests: XCTestCase {
    private var wholeText: String {
        UserGuide.sections.map { section in
            ([section.title]
                + section.blocks.map { block -> String in
                    switch block {
                    case .text(let text), .heading(let text): return text
                    case .steps(let steps): return steps.joined(separator: "\n")
                    case .terms(let terms): return terms.map { "\($0.name)\n\($0.text)" }.joined(separator: "\n")
                    }
                }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func testEveryControlOfTheWindowIsExplained() {
        let text = wholeText
        for control in [
            "Open…", "Shapes", "Size", "Min width", "Limit folds", "Folds", "Strength", "Gradients",
            "Steps", "Kind", "Curves", "Tiles", "Cuts", "Strict tree", "Worst first", "Levels",
            "Re-fit", "Prefix", "Parent", "Refine selection", "Start", "Restart", "Cancel",
            "Refined areas", "Level", "Depth", "Hold: original", "Export SVG…",
        ] {
            XCTAssertTrue(text.contains("**\(control)**"), "the guide does not explain \(control)")
        }
    }

    func testSectionsHaveDistinctTitlesAndSomethingToSay() {
        XCTAssertGreaterThanOrEqual(UserGuide.sections.count, 6)
        XCTAssertEqual(Set(UserGuide.sections.map(\.title)).count, UserGuide.sections.count)
        for section in UserGuide.sections {
            XCTAssertFalse(section.blocks.isEmpty, section.title)
        }
    }

    func testTheChoicesNamedAreTheOnesOffered() {
        let text = wholeText
        let shapes = FitModel.shapeChoices
        XCTAssertTrue(text.contains("\(shapes.first!) to \(shapes.last!)"))
        let sizes = FitModel.sizeChoices
        XCTAssertTrue(text.contains("\(sizes.first!) to \(sizes.last!) pixels"))
        XCTAssertTrue(
            text.contains("\(FitModel.stepsRange.lowerBound) to \(FitModel.stepsRange.upperBound)"))
    }
}
