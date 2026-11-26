import Foundation

/// A semantic version (semver.org): `major.minor.patch`, an optional pre-release (`-beta.2`) and build metadata
/// (`+abc123`, kept but ignored when comparing). Parsing is lenient where release tags are: a leading "v", and a
/// missing minor or patch number (read as 0).
///
/// Ordering follows semver's precedence: the numbers first, then a pre-release sorts before the release it leads to
/// (1.2.0-beta < 1.2.0), pre-release identifiers compared one by one (numeric ones as numbers and before alphanumeric
/// ones, alphanumeric ones in ASCII order, and a shorter list first when all before it are equal).
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The pre-release identifiers, empty for a release
    public var preRelease: [String]
    /// The build metadata, empty when there is none
    public var build: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, preRelease: [String] = [], build: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
        self.build = build
    }

    /// Nil for text that is not a version
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var build: [String] = []
        if let plus = rest.firstIndex(of: "+") {
            build = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard build.allSatisfy(Self.isIdentifier) else { return nil }
            rest = rest[..<plus]
        }
        var preRelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            preRelease = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard preRelease.allSatisfy(Self.isIdentifier) else { return nil }
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count),
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let values = numbers.compactMap { Int($0) }
        guard values.count == numbers.count else { return nil }
        self.init(major: values[0], minor: values.count > 1 ? values[1] : 0, patch: values.count > 2 ? values[2] : 0,
                  preRelease: preRelease, build: build)
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
            + (build.isEmpty ? "" : "+" + build.joined(separator: "."))
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Precedence: negative, zero or positive as `a` comes before, alongside or after `b` (build metadata ignored)
    public static func compare(_ a: SemanticVersion, _ b: SemanticVersion) -> Int {
        for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)] where x != y { return x < y ? -1 : 1 }
        switch (a.preRelease.isEmpty, b.preRelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for (x, y) in zip(a.preRelease, b.preRelease) {
            switch (Int(x), Int(y)) {
            case let (m?, n?): if m != n { return m < n ? -1 : 1 }
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): if x != y { return x < y ? -1 : 1 }
            }
        }
        return a.preRelease.count == b.preRelease.count ? 0 : (a.preRelease.count < b.preRelease.count ? -1 : 1)
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool { compare(a, b) < 0 }
    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { compare(a, b) == 0 }
}

/// This build's version. bundle.sh stamps macos/VERSION, the build number and the commit into the app's Info.plist
/// (and the Audio Unit's); the app, the Audio Unit and `jspice-mcp` (in the same Contents/MacOS folder as the app)
/// read it from there. Built with `swift build` or `swift test`, nothing is stamped and `fallback` is used: a test checks
/// it against macos/VERSION.
public enum JSpiceVersion {
    /// Keep equal to macos/VERSION (VersionTests checks)
    public static let fallback = "1.1.0"

    /// The Info.plist of the bundle this executable sits in (Something.app/Contents/MacOS/executable), if it is one of
    /// JSpice's; empty otherwise
    public static let info: [String: String] = {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ""))
            .resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["CFBundleIdentifier"] as? String)?.hasPrefix("org.knowm.jspice") == true else { return [:] }
        return plist.compactMapValues { $0 as? String }
    }()

    /// The full semantic version (pre-release included, which CFBundleShortVersionString cannot hold)
    public static var version: String { info["JSpiceVersion"] ?? info["CFBundleShortVersionString"] ?? fallback }
    /// The build number (CFBundleVersion), nil when not built by bundle.sh
    public static var build: String? { info["CFBundleVersion"] }
    /// The short commit hash the build was made from, nil when unknown
    public static var commit: String? { info["JSpiceCommit"].flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 } }

    /// "1.1.0 (build 412, commit 1a2b3c4)", or "1.1.0 (development build)" when not packaged
    public static var description: String {
        let details = [build.map { "build \($0)" }, commit.map { "commit \($0)" }].compactMap { $0 }
        return version + " (" + (details.isEmpty ? "development build" : details.joined(separator: ", ")) + ")"
    }

    /// Whether `latest` (a release's tag, such as "v1.2.0") is newer than `current`; nil when either is not a version
    public static func isUpdate(latest: String, current: String = version) -> Bool? {
        guard let latest = SemanticVersion(latest), let current = SemanticVersion(current) else { return nil }
        return current < latest
    }
}

/// The parts of a GitHub Releases API answer (`GET /repos/{owner}/{repo}/releases/latest`) an update check needs
public struct LatestRelease: Equatable, Sendable {
    public var tag: String
    public var name: String?
    /// The release's page, only ever on https://github.com/
    public var page: URL?

    public init(tag: String, name: String? = nil, page: URL? = nil) {
        self.tag = tag
        self.name = name
        self.page = page
    }

    /// Nil for anything that is not a published release
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              object["draft"] as? Bool != true else { return nil }
        self.tag = tag
        name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        page = (object["html_url"] as? String).flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" && $0.host == "github.com" ? $0 : nil
        }
    }
}
