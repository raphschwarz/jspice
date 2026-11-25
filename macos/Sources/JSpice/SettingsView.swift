import AppKit
import Combine
import Security
import SwiftUI
import CircuitKit

/// JSpice ▸ Settings… (⌘,): AI control, the Anthropic API key, and chip support
struct SettingsView: View {
    var body: some View {
        TabView {
            AIControlSettings()
                .tabItem { Label("AI Control", systemImage: "sparkles") }
            APIKeySettings()
                .tabItem { Label("API Key", systemImage: "key") }
            ChipSupportSettings()
                .tabItem { Label("Chip Support", systemImage: "cpu") }
        }
    }
}

// MARK: - AI Control

/// Whether AI agents may drive JSpice through its MCP server, whether it is listening for them, and how to connect one
struct AIControlSettings: View {
    // kept up to date when the consent prompt's Always Allow changes the choice, as the menu is
    @AppStorage(AIControlMode.defaultsKey) private var mode: AIControlMode = .ask
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Picker("Let AI agents control JSpice", selection: Binding(
                    get: { mode },
                    set: { AutomationBridge.shared.mode = $0 }
                )) {
                    Text("Ask When an Agent Connects").tag(AIControlMode.ask)
                    Text("Always Allow").tag(AIControlMode.always)
                    Text("Don't Allow").tag(AIControlMode.off)
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Ask When an Agent Connects:** the first agent to connect after JSpice starts brings up a prompt. Allow lets agents work until you quit JSpice; Don't Allow refuses them until then.")
                    Text("**Always Allow:** any agent that connects gets control without a prompt.")
                    Text("**Don't Allow:** JSpice does not listen for agents. jspice-mcp then simulates on its own, without this app's windows.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Status") { Text(status) }
                }
            } header: {
                Text("AI Agents (MCP)")
            } footer: {
                Text("An agent in control can change the open circuit, read and write files anywhere your account can, install chip support and open a debugging port. JSpice cannot tell which program is connecting, only that it runs as you on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("1. Copy the configuration and paste it into Claude Desktop's configuration file (in Claude Desktop, Settings ▸ Developer ▸ Edit Config), then restart Claude Desktop.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("2. Or, for Claude Code, run this in Terminal:")
                    Text(verbatim: "claude mcp add jspice \(AutomationBridge.serverCommand)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy MCP Server Configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AutomationBridge.clientConfiguration, forType: .string)
                        copied = true
                    }
                    if copied {
                        Text("Copied").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Connect an Agent")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }

    private var status: String {
        if mode == .off { return "Not listening: AI control is off" }
        if AutomationBridge.shared.isListening { return "Listening for agents" }
        return "Not listening: another copy of JSpice may be serving agents"
    }
}

// MARK: - API Key

/// The Anthropic API key schematic capture uses: whether there is one and where it comes from (never the key itself),
/// and a field to enter or replace it
struct APIKeySettings: View {
    @State private var stored = false
    @State private var entry = ""

    private var trimmed: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// APIKeyStore.key prefers this variable to the keychain
    private var fromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Anthropic API key") { Text(status) }
                Text("Reading a schematic drawing (File ▸ Import ▸ Schematic from Image or PDF…) sends it to Claude through the Anthropic API with this key, billed to your API account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                SecureField("Key", text: $entry, prompt: Text(verbatim: "sk-ant-…"))
                HStack {
                    Button("Remove", role: .destructive) {
                        APIKeyStore.remove()
                        refresh()
                    }
                    .disabled(!stored)
                    Spacer()
                    Button(stored ? "Replace" : "Save") {
                        APIKeyStore.save(trimmed)
                        entry = ""
                        refresh()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
                }
            } header: {
                Text(stored ? "Replace the Stored Key" : "Enter a Key")
            } footer: {
                Text("Create a key at console.anthropic.com. JSpice keeps it in your login keychain and never shows it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 340)
        .onAppear(perform: refresh)
    }

    private var status: String {
        if fromEnvironment {
            return stored ? "From the ANTHROPIC_API_KEY environment variable (used in place of the stored one)"
                          : "From the ANTHROPIC_API_KEY environment variable"
        }
        return stored ? "Stored in your login keychain" : "None"
    }

    private func refresh() {
        stored = Self.keychainHasKey
    }

    /// Whether the login keychain holds APIKeyStore's item. Only its attributes are asked for, so that looking never
    /// brings up a keychain prompt for the key itself. (The service name is APIKeyStore's, which keeps it private.)
    private static var keychainHasKey: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "org.knowm.jspice.anthropic-api-key",
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}

// MARK: - Chip Support

/// What each chip family's compiler is, as Chip Support shows it. Installing and removing stay in the Chip Support
/// sheet, which belongs to a circuit window (its Done button closes the window's sheet), so this opens it there.
struct ChipSupportSettings: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(ChipFamily.allCases) { family in
                    LabeledContent {
                        Text(status(family))
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text(family.title)
                        Text(family.summary)
                    }
                }
            } header: {
                Text("Compilers")
            } footer: {
                Text("Microcontrollers run real firmware compiled from your sketch. JSpice downloads each family's compiler and Arduino core once, from their makers' package indexes, into its Application Support folder. STM32 chips run firmware built elsewhere, and need none.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(refresh)
            Section {
                HStack {
                    Text(EditorRegistry.active == nil ? "Open a circuit window to install or remove chip support."
                                                      : "Install and remove chip support in the circuit window.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Chip Support…", action: openSheet)
                        .disabled(EditorRegistry.active == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
        .onAppear { refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh += 1 }
    }

    private func status(_ family: ChipFamily) -> String {
        if let versions = ChipSupport.installedVersions(family) {
            return "Installed: \(family.compilerFolder) \(versions.compiler), \(family.coreName) \(versions.core)"
        }
        if ChipSupport.isAvailable(family) { return "Using an Arduino IDE's toolchain" }
        return "Not installed"
    }

    /// Shows the Chip Support sheet in the circuit window used last, and closes Settings so that it can be seen
    private func openSheet() {
        guard let editor = EditorRegistry.active else { return }
        let settingsWindow = NSApp.keyWindow
        editor.showChipSupport = true
        settingsWindow?.close()
    }
}
