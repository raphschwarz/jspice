import AppKit
import AudioToolbox
import CoreAudioKit
import SwiftUI
import CircuitKit

/// The extension's principal class: makes the Audio Unit for the host, and its window, which chooses the circuit
/// and turns its knobs
@objc(JSpiceAudioUnitViewController)
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: CircuitAudioUnit?

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try CircuitAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        Task { @MainActor [weak self] in self?.show(unit) }
        return unit
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        preferredContentSize = view.frame.size
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if let audioUnit { show(audioUnit) }
    }

    private func show(_ unit: CircuitAudioUnit) {
        guard isViewLoaded, view.subviews.isEmpty else { return }
        let host = NSHostingView(rootView: PluginPanel(model: PluginModel(unit)))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
    }
}

/// What the plugin's window shows: the circuits to choose from, and the knobs and switches of the one playing
@MainActor
final class PluginModel: ObservableObject {
    struct Knob: Identifiable {
        let id: Int
        let name: String
        let isSwitch: Bool
        var value: Double
    }

    let unit: CircuitAudioUnit
    @Published var names: [String] = []
    @Published var selected = 0
    @Published var circuitName = ""
    @Published var knobs: [Knob] = []
    private var token: AUParameterObserverToken?

    init(_ unit: CircuitAudioUnit) {
        self.unit = unit
        unit.onLoad = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        names = unit.library.map(\.name)
        circuitName = unit.circuitName
        selected = unit.currentPreset.map { $0.number } ?? -1
        if let token, let old = unit.parameterTree { old.removeParameterObserver(token) }
        let parameters = unit.parameterTree?.allParameters ?? []
        knobs = parameters.map { Knob(id: Int($0.address), name: $0.displayName, isSwitch: $0.unit == .boolean, value: Double($0.value)) }
        // the host's automation moves the knobs on screen
        token = unit.parameterTree?.token(byAddingParameterObserver: { [weak self] address, value in
            Task { @MainActor [weak self] in
                guard let self, let k = self.knobs.firstIndex(where: { $0.id == Int(address) }) else { return }
                self.knobs[k].value = Double(value)
            }
        })
    }

    func choose(_ index: Int) {
        guard let preset = unit.factoryPresets?.first(where: { $0.number == index }) else { return }
        unit.currentPreset = preset
    }

    func set(_ knob: Knob, _ value: Double) {
        guard let k = knobs.firstIndex(where: { $0.id == knob.id }) else { return }
        knobs[k].value = value
        unit.parameterTree?.parameter(withAddress: AUParameterAddress(knob.id))?.setValue(AUValue(value), originator: token)
    }

    func reload() {
        unit.reloadLibrary()
        names = unit.library.map(\.name)
    }
}

struct PluginPanel: View {
    @ObservedObject var model: PluginModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Circuit", selection: Binding(get: { model.selected }, set: { model.choose($0) })) {
                    if model.selected < 0 { Text(model.circuitName).tag(-1) }
                    ForEach(Array(model.names.enumerated()), id: \.offset) { k, name in Text(name).tag(k) }
                }
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Look again for circuits exported from JSpice")
            }
            if model.knobs.isEmpty {
                Text("This circuit has no knobs or switches.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.knobs) { knob in
                            if knob.isSwitch {
                                Toggle(knob.name, isOn: Binding(get: { knob.value >= 0.5 }, set: { model.set(knob, $0 ? 1 : 0) }))
                            } else {
                                HStack {
                                    Text(knob.name).frame(width: 110, alignment: .leading)
                                    Slider(value: Binding(get: { knob.value }, set: { model.set(knob, $0) }), in: 0...1)
                                    Text("\(Int((knob.value * 100).rounded()))").monospacedDigit().frame(width: 32, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Design a circuit in JSpice, then File ▸ Export as Audio Unit to play it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260)
    }
}
