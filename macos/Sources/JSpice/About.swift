import AppKit
import SwiftUI
import CircuitKit

// JSpice ▸ About JSpice (the standard About panel, with the build and the commit) and JSpice ▸ Check for Updates….
// The menu items are added in AppMenuCommands:
//     CommandGroup(replacing: .appInfo) { AboutJSpiceButton() }
//     CommandGroup(after: .appInfo) { CheckForUpdatesButton() }

/// Where JSpice's releases are published: the one place the repository is named
enum JSpiceReleases {
    /// owner/name of the GitHub repository (as in the git remote and the README's build badge)
    static let repository = "raphschwarz/jspice"
    /// GitHub's answer for the newest published release (drafts and pre-releases are left out)
    static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let page = URL(string: "https://github.com/\(repository)/releases")!
}

/// JSpice ▸ About JSpice
struct AboutJSpiceButton: View {
    var body: some View {
        Button("About JSpice") { AboutPanel.show() }
    }
}

/// JSpice ▸ Check for Updates…
@MainActor struct CheckForUpdatesButton: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        Button("Check for Updates…") { checker.check() }
            .disabled(checker.isChecking)
    }
}

enum AboutPanel {
    /// The standard panel, its version line reading "Version 1.1.0 (build 412, commit 1a2b3c4)"
    @MainActor static func show() {
        let details = [JSpiceVersion.build.map { "build \($0)" }, JSpiceVersion.commit.map { "commit \($0)" }]
            .compactMap { $0 }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: JSpiceVersion.version,
            .version: details.isEmpty ? "development build" : details.joined(separator: ", "),
        ])
    }
}

/// Asks GitHub for the newest release, only when the user chooses Check for Updates… (never by itself), with a plain
/// GET that carries no cookies, no stored credentials and no identifier of the user or the Mac, and says what it found.
@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false

    static let privacyNote = "JSpice contacts GitHub only when you choose Check for Updates. It asks api.github.com for "
        + "the newest release of \(JSpiceReleases.repository) and sends nothing about you, your Mac or your circuits "
        + "beyond what any web request reveals, such as your IP address."

    func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let outcome = await Self.fetch()
            isChecking = false
            present(outcome)
        }
    }

    enum Outcome {
        case newer(LatestRelease)
        case upToDate(LatestRelease)
        case noReleases
        case failed(String)
    }

    nonisolated static func fetch() async -> Outcome {
        // ephemeral: no cookies, cache or credentials kept or sent
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: JSpiceReleases.latestAPI, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a user agent: a fixed one, without the version, build or system the default would add
        request.setValue("JSpice-update-check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .noReleases }
            guard status == 200 else {
                return .failed(status == 403 || status == 429
                    ? "GitHub is limiting requests from this network for now. Try again later."
                    : "GitHub answered with status \(status).")
            }
            guard let release = LatestRelease(json: data) else { return .failed("GitHub's answer could not be read.") }
            switch JSpiceVersion.isUpdate(latest: release.tag) {
            case true?: return .newer(release)
            case false?: return .upToDate(release)
            case nil: return .failed("The newest release's tag, \(release.tag), is not a version JSpice can compare.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func present(_ outcome: Outcome) {
        let alert = NSAlert()
        let current = JSpiceVersion.version
        switch outcome {
        case .newer(let release):
            let version = SemanticVersion(release.tag)?.description ?? release.tag
            alert.messageText = "JSpice \(version) is available"
            alert.informativeText = "You have JSpice \(current). Download the new version from its release page.\n\n"
                + Self.privacyNote
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.page ?? JSpiceReleases.page)
            }
            return
        case .upToDate:
            alert.messageText = "JSpice is up to date"
            alert.informativeText = "JSpice \(current) is the newest version.\n\n" + Self.privacyNote
        case .noReleases:
            alert.messageText = "No releases yet"
            alert.informativeText = "No release of JSpice has been published yet. You have JSpice \(current).\n\n"
                + Self.privacyNote
        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates"
            alert.informativeText = reason + "\n\n" + Self.privacyNote
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
