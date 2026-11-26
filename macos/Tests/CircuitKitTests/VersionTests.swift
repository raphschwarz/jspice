import XCTest
@testable import CircuitKit

final class VersionTests: XCTestCase {
    func v(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SemanticVersion {
        guard let version = SemanticVersion(text) else {
            XCTFail("\(text) should parse", file: file, line: line)
            return SemanticVersion(major: 0)
        }
        return version
    }

    func testParsing() {
        XCTAssertEqual(v("1.2.3").description, "1.2.3")
        XCTAssertEqual(v("v1.2.3").description, "1.2.3")
        XCTAssertEqual(v(" V2.0 ").description, "2.0.0")
        XCTAssertEqual(v("3").description, "3.0.0")
        XCTAssertEqual(v("1.2.3-beta.2+exp.sha.5114f85").description, "1.2.3-beta.2+exp.sha.5114f85")
        XCTAssertEqual(v("1.2.3-rc.1").preRelease, ["rc", "1"])
        XCTAssertTrue(v("1.0.0-alpha").isPreRelease)
        XCTAssertFalse(v("1.0.0").isPreRelease)
        for bad in ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-beta..1", "1.2.3+", "1.2.3-be ta",
                    "１.2.3", "-1.2.3", "latest"] {
            XCTAssertNil(SemanticVersion(bad), "\(bad) should not parse")
        }
    }

    func testPrecedence() {
        // semver.org's example order, plus the numbers
        let ordered = ["0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0"]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                XCTAssertEqual(v(a) < v(b), i < j, "\(a) < \(b)")
                XCTAssertEqual(v(a) == v(b), i == j, "\(a) == \(b)")
            }
        }
        XCTAssertEqual(v("v1.2.0"), v("1.2"))
        XCTAssertEqual(v("1.2.0+build.1"), v("1.2.0+build.2"))
    }

    func testIsUpdate() {
        XCTAssertEqual(JSpiceVersion.isUpdate(latest: "v1.2.0", current: "1.1.0"), true)
        XCTAssertEqual(JSpiceVersion.isUpdate(latest: "v1.1.0", current: "1.1.0"), false)
        XCTAssertEqual(JSpiceVersion.isUpdate(latest: "v1.0.9", current: "1.1.0"), false)
        // a pre-release of this version is older than it; the release after a pre-release is newer
        XCTAssertEqual(JSpiceVersion.isUpdate(latest: "v1.1.0-rc.1", current: "1.1.0"), false)
        XCTAssertEqual(JSpiceVersion.isUpdate(latest: "v1.1.0", current: "1.1.0-rc.1"), true)
        XCTAssertNil(JSpiceVersion.isUpdate(latest: "nightly", current: "1.1.0"))
    }

    func testLatestRelease() throws {
        let json = #"{"tag_name":"v1.2.0","name":"JSpice 1.2.0","draft":false,"prerelease":false,"#
            + #""html_url":"https://github.com/owner/repo/releases/tag/v1.2.0"}"#
        let release = try XCTUnwrap(LatestRelease(json: Data(json.utf8)))
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.name, "JSpice 1.2.0")
        XCTAssertEqual(release.page?.absoluteString, "https://github.com/owner/repo/releases/tag/v1.2.0")
        // a page anywhere but github.com is not offered
        let elsewhere = #"{"tag_name":"v1.2.0","html_url":"http://example.com/x"}"#
        XCTAssertNil(LatestRelease(json: Data(elsewhere.utf8))?.page)
        XCTAssertNil(LatestRelease(json: Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(LatestRelease(json: Data(#"{"tag_name":"v2.0.0","draft":true}"#.utf8)))
        XCTAssertNil(LatestRelease(json: Data("not json".utf8)))
    }

    /// Unpackaged (as under `swift test`), the version is the fallback constant, which must match macos/VERSION
    func testFallbackMatchesVersionFile() throws {
        XCTAssertTrue(JSpiceVersion.info.isEmpty)
        XCTAssertEqual(JSpiceVersion.version, JSpiceVersion.fallback)
        XCTAssertNotNil(SemanticVersion(JSpiceVersion.fallback))
        // macos/Tests/CircuitKitTests/VersionTests.swift → macos/VERSION
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VERSION")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            #if os(Linux)
            // (the Linux shadow package links the tests in from elsewhere, where there is no VERSION beside them)
            throw XCTSkip("no VERSION file at \(file.path)")
            #else
            XCTFail("no VERSION file at \(file.path)")
            return
            #endif
        }
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), JSpiceVersion.fallback,
                       "JSpiceVersion.fallback (Sources/CircuitKit/Version.swift) must match macos/VERSION")
    }
}
