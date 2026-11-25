import SwiftUI
import CircuitKit

let speedPresets: [Double] = [1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 5e-3, 2e-3, 1e-3, 5e-4, 2e-4, 1e-4, 1e-5, 1e-6]

/// The window toolbar: run and reset, the speed, sound, the view (schematic or a board) and what the canvas shows
struct EditorToolbar: ToolbarContent {
    @ObservedObject var editor: EditorState
    @ObservedObject var simulation: SimulationController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                simulation.toggleRunning()
            } label: {
                Label(simulation.isRunning ? "Pause" : "Run", systemImage: simulation.isRunning ? "pause.fill" : "play.fill")
            }
            .help(simulation.isRunning ? "Pause the simulation (Space)" : "Run the simulation (Space)")
            Button {
                simulation.reset()
            } label: {
                Label("Reset", systemImage: "backward.end.fill")
            }
            .help("Restart from time zero, with capacitors discharged")
        }
        ToolbarItem(placement: .principal) {
            Menu {
                Button("Automatic") { editor.updateSettings { $0.autoSpeed = true } }
                Divider()
                ForEach(speedPresets, id: \.self) { speed in
                    Button(Pacing.describe(speed: speed)) {
                        editor.updateSettings {
                            $0.autoSpeed = false
                            $0.speed = speed
                        }
                    }
                }
            } label: {
                Label(Pacing.describe(speed: simulation.status.speed), systemImage: "speedometer")
                    .labelStyle(.titleAndIcon)
            }
            .help("How fast circuit time runs compared with real time")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { simulation.soundOn }, set: { simulation.setSound($0) })) {
                Label("Sound", systemImage: simulation.soundOn ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .disabled(!simulation.hasSpeaker)
            .help(simulation.hasSpeaker ? "Listen to the speaker: runs the circuit in real time at audio rate"
                                        : "Add a speaker to the circuit to listen to it")
            Picker("View", selection: $editor.board) {
                Label("Schematic", systemImage: "point.3.connected.trianglepath.dotted").tag(BoardKind.schematic)
                Label("Breadboard", systemImage: "circle.grid.3x3").tag(BoardKind.breadboard)
                Label("Stripboard", systemImage: "line.3.horizontal").tag(BoardKind.stripboard)
                Label("Perfboard", systemImage: "circle.grid.2x2").tag(BoardKind.perfboard)
            }
            .pickerStyle(.segmented)
            .help("Show the schematic, or the circuit built on a solderless breadboard (full or half size), stripboard or perfboard, with its bill of materials")
            Toggle(isOn: $editor.showPanel) {
                Label("Panel", systemImage: "slider.horizontal.3")
            }
            .help("Show the front panel: knobs and switches for the circuit's potentiometers and switches")
            Toggle(isOn: $editor.showCurrent) {
                Label("Current", systemImage: "bolt.fill")
            }
            .help("Show current flow as moving dots")
            Toggle(isOn: $editor.showValues) {
                Label("Values", systemImage: "textformat.123")
            }
            .help("Show part names and values")
            Button { editor.changeZoom(by: 0.8) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            Button { editor.changeZoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            Button { editor.requestFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
            Button {
                editor.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }
}
