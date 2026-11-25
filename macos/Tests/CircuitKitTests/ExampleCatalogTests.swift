import XCTest
@testable import CircuitKit

/// The example gallery's catalogue: categories, featured examples and badges
final class ExampleCatalogTests: XCTestCase {
    func testIdsAreUnique() {
        let ids = Examples.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    func testEveryExampleHasACategory() {
        let missing = Examples.all.map(\.id).filter { Examples.categories[$0] == nil }
        XCTAssertEqual(missing, [], "examples without a category")
        let ids = Set(Examples.all.map(\.id))
        let stale = Examples.categories.keys.filter { !ids.contains($0) }.sorted()
        XCTAssertEqual(stale, [], "categorised ids that are not examples")
    }

    func testEveryCategoryHasExamples() {
        for category in ExampleCategory.allCases {
            XCTAssertFalse(category.examples.isEmpty, "\(category.displayName) is empty")
        }
        XCTAssertEqual(ExampleCategory.allCases.map { $0.examples.count }.reduce(0, +), Examples.all.count)
    }

    func testFeaturedExamplesExist() {
        XCTAssertFalse(Examples.featured.isEmpty)
        for group in Examples.featured {
            XCTAssertFalse(group.ids.isEmpty, group.title)
            for id in group.ids {
                XCTAssertNotNil(Examples.example(id), "featured example \(id) in \(group.title) does not exist")
            }
            XCTAssertEqual(group.examples.count, group.ids.count)
        }
    }

    /// The badges known without building a circuit agree with the built circuit
    func testQuickFeaturesMatchTheCircuits() {
        for example in Examples.all {
            let built = Example.features(of: example.circuit)
            let quick = example.quickFeatures
            XCTAssertEqual(quick.contains(.sound), built.contains(.sound),
                           "\(example.id): sound from its text \(quick.contains(.sound)), speaker in its circuit \(built.contains(.sound))")
            XCTAssertEqual(quick.contains(.microcontroller), built.contains(.microcontroller),
                           "\(example.id): microcontroller from its category \(quick.contains(.microcontroller)), in its circuit \(built.contains(.microcontroller))")
        }
    }

    func testCategoryCounts() {
        for category in ExampleCategory.allCases {
            print("\(category.displayName): \(category.examples.count)")
        }
    }
}
