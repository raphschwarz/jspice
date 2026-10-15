import Foundation

/// Where KiCad is installed, and what it has: its command-line tool, its PCB editor, its stock footprint libraries and
/// its settings. JSpice finds KiCad where its installers put it (on a Mac, /Applications/KiCad/KiCad.app) or where
/// KICAD_CLI, KICAD10_FOOTPRINT_DIR and the like say it is.
public struct KiCadInstallation: Sendable, Hashable {
    /// kicad-cli
    public var cli: URL
    /// The app that opens a board (KiCad.app's pcbnew.app on a Mac, pcbnew elsewhere), if there is one
    public var pcbEditor: URL?
    /// The stock footprint libraries (…/footprints, holding one .pretty folder a library)
    public var footprints: URL?
    /// The stock 3D models
    public var models3D: URL?
    /// The board and project templates
    public var templates: URL?
    /// "10.0.7"
    public var version: String

    public init(cli: URL, pcbEditor: URL?, footprints: URL?, models3D: URL?, templates: URL?, version: String) {
        (self.cli, self.pcbEditor, self.footprints, self.models3D, self.templates, self.version) =
            (cli, pcbEditor, footprints, models3D, templates, version)
    }

    public var major: Int { Int(version.split(separator: ".").first ?? "") ?? 0 }

    /// "10.0", the folder KiCad keeps this version's settings in
    public var settingsVersion: String { "\(major).0" }

    /// The oldest KiCad whose boards JSpice writes (10, which names nets on items rather than numbering them)
    public static let minimumMajor = 10

    /// KiCad's settings folder for this version: ~/Library/Preferences/kicad/10.0 on a Mac, ~/.config/kicad/10.0
    /// elsewhere (KICAD_CONFIG_HOME if set)
    public func settings(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["KICAD_CONFIG_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent(settingsVersion) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Preferences/kicad/\(settingsVersion)")
        #else
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("kicad/\(settingsVersion)")
        #endif
    }

    /// The variables KiCad sets for its library tables: KICAD10_FOOTPRINT_DIR and the rest, and the user's own from
    /// kicad_common.json
    public func variables(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var vars: [String: String] = [:]
        for prefix in ["KICAD\(major)", "KICAD"] {
            if let f = footprints { vars["\(prefix)_FOOTPRINT_DIR"] = f.path }
            if let m = models3D { vars["\(prefix)_3DMODEL_DIR"] = m.path }
            if let t = templates { vars["\(prefix)_TEMPLATE_DIR"] = t.path }
            if let f = footprints { vars["\(prefix)_SYMBOL_DIR"] = f.deletingLastPathComponent().appendingPathComponent("symbols").path }
        }
        vars["KICAD\(major)_3RD_PARTY"] = settings(environment: environment).appendingPathComponent("3rdparty").path
        // the user's own variables
        let common = settings(environment: environment).appendingPathComponent("kicad_common.json")
        if let data = try? Data(contentsOf: common),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = json["environment"] as? [String: Any], let user = env["vars"] as? [String: String] {
            vars.merge(user) { _, mine in mine }
        }
        // and the process's, which win as they do in KiCad
        for (k, v) in environment where k.hasPrefix("KICAD") { vars[k] = v }
        return vars
    }

    /// The installation to use: KICAD_CLI's, or the first one found where KiCad installs itself
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> KiCadInstallation? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let cli = environment["KICAD_CLI"] { candidates.append(URL(fileURLWithPath: cli)) }
        for app in ["/Applications/KiCad/KiCad.app", "/Applications/KiCad.app",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/KiCad/KiCad.app").path] {
            candidates.append(URL(fileURLWithPath: app).appendingPathComponent("Contents/MacOS/kicad-cli"))
        }
        candidates += ["/usr/bin/kicad-cli", "/usr/local/bin/kicad-cli", "/opt/homebrew/bin/kicad-cli"].map { URL(fileURLWithPath: $0) }
        for cli in candidates where fm.isExecutableFile(atPath: cli.path) {
            return describe(cli: cli.resolvingSymlinksInPath(), environment: environment)
        }
        return nil
    }

    /// An installation from where its kicad-cli is
    public static func describe(cli: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> KiCadInstallation {
        let fm = FileManager.default
        let contents = cli.deletingLastPathComponent().deletingLastPathComponent()
        var shared: URL?
        var editor: URL?
        if contents.lastPathComponent == "Contents" {
            // KiCad.app/Contents/MacOS/kicad-cli
            shared = contents.appendingPathComponent("SharedSupport")
            editor = contents.appendingPathComponent("Applications/pcbnew.app")
        } else {
            // /usr/bin/kicad-cli, /usr/share/kicad
            shared = contents.appendingPathComponent("share/kicad")
            let pcbnew = cli.deletingLastPathComponent().appendingPathComponent("pcbnew")
            if fm.isExecutableFile(atPath: pcbnew.path) { editor = pcbnew }
        }
        func existing(_ url: URL?) -> URL? { url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } }
        let version = (try? KiCadCLI.run(cli, ["version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        var install = KiCadInstallation(cli: cli, pcbEditor: existing(editor),
                                        footprints: existing(shared?.appendingPathComponent("footprints")),
                                        models3D: existing(shared?.appendingPathComponent("3dmodels")),
                                        templates: existing(shared?.appendingPathComponent("template")),
                                        version: version)
        // the libraries' own variables point elsewhere if KiCad's were moved
        let major = install.major
        if let dir = environment["KICAD\(major)_FOOTPRINT_DIR"] { install.footprints = URL(fileURLWithPath: dir) }
        if let dir = environment["KICAD\(major)_3DMODEL_DIR"] { install.models3D = URL(fileURLWithPath: dir) }
        return install
    }

    /// Why this KiCad cannot be used, if it cannot
    public var problem: String? {
        if version.isEmpty { return "\(cli.path) did not say which version of KiCad it is." }
        if major < KiCadInstallation.minimumMajor {
            return "JSpice works with KiCad \(KiCadInstallation.minimumMajor) or later; this is KiCad \(version). Install the latest KiCad from kicad.org."
        }
        return nil
    }
}

/// Running kicad-cli
public enum KiCadCLI {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Runs `tool` with `arguments`, waiting for it to finish
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // read both pipes as the tool writes, so a full one cannot stall it
        final class Collected: @unchecked Sendable { var data = Data() }
        let output = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { output.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self))
    }
}
