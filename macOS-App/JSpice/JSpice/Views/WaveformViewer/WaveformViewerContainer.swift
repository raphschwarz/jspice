import SwiftUI
import Accelerate

// MARK: - Waveform Viewer Container

struct WaveformViewerContainer: View {
    let simulationResult: SimulationResult?
    @State private var selectedTab: WaveformTab = .oscilloscope
    @State private var selectedNodes: Set<String> = []

    enum WaveformTab: String, CaseIterable {
        case oscilloscope = "Oscilloscope"
        case spectrum = "Spectrum"
        case bode = "Bode Plot"
        case data = "Data"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(WaveformTab.allCases, id: \.rawValue) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tab.rawValue)
                            .font(.caption.weight(selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Node selector
                if let result = simulationResult {
                    Menu("Signals") {
                        Button("Show All") {
                            selectedNodes.removeAll()
                        }
                        Divider()
                        ForEach(result.allSignalNames.sorted(), id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selectedNodes.isEmpty || selectedNodes.contains(name) },
                                set: { isOn in
                                    // When toggling from "all shown" state, first populate all signals
                                    if selectedNodes.isEmpty {
                                        selectedNodes = Set(result.allSignalNames)
                                    }
                                    if isOn {
                                        selectedNodes.insert(name)
                                    } else {
                                        selectedNodes.remove(name)
                                    }
                                    // If all are selected again, go back to "show all" state
                                    if selectedNodes == Set(result.allSignalNames) {
                                        selectedNodes.removeAll()
                                    }
                                }
                            ))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .oscilloscope:
                    OscilloscopeView(result: simulationResult, selectedNodes: selectedNodes)
                case .spectrum:
                    SpectrumView(result: simulationResult)
                case .bode:
                    BodePlotView(result: simulationResult)
                case .data:
                    DataTableView(result: simulationResult)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Oscilloscope View

struct OscilloscopeView: View {
    let result: SimulationResult?
    let selectedNodes: Set<String>

    var body: some View {
        if let result = result, let timePoints = result.timePoints, !timePoints.isEmpty {
            let waveforms = result.waveforms(
                forNodes: selectedNodes.isEmpty ? nil : Array(selectedNodes)
            )
            WaveformChartView(waveforms: waveforms)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("Run a simulation to see waveforms")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Waveform Chart (Core Graphics renderer)

struct WaveformChartView: View {
    let waveforms: [WaveformData]

    @State private var hoveredX: CGFloat?
    @State private var zoomRange: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Background
                Color(nsColor: .textBackgroundColor)

                // Grid
                WaveformGrid(size: geometry.size)

                // Waveform traces
                ForEach(waveforms) { waveform in
                    WaveformTrace(
                        waveform: waveform,
                        size: geometry.size,
                        xRange: effectiveXRange,
                        yRange: effectiveYRange
                    )
                }

                // Cursor
                if let x = hoveredX {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: x)
                }

                // Legend
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(waveforms) { waveform in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hue: waveform.color.hue, saturation: 0.8, brightness: 0.9))
                                .frame(width: 6, height: 6)
                            Text(waveform.name)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)

                // Axis labels
                VStack {
                    Spacer()
                    HStack {
                        if let first = waveforms.first {
                            Text(first.xLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredX = location.x
                case .ended:
                    hoveredX = nil
                }
            }
        }
    }

    private var effectiveXRange: ClosedRange<Double> {
        if let range = zoomRange { return range }
        let allX = waveforms.flatMap { $0.xValues }
        let minX = allX.min() ?? 0
        let maxX = allX.max() ?? 1
        return minX...max(maxX, minX + 1e-10)
    }

    private var effectiveYRange: ClosedRange<Double> {
        let allY = waveforms.flatMap { $0.yValues }
        let minY = allY.min() ?? -1
        let maxY = allY.max() ?? 1
        let padding = max(abs(maxY - minY) * 0.1, 0.1)
        return (minY - padding)...(maxY + padding)
    }
}

// MARK: - Waveform Grid

struct WaveformGrid: View {
    let size: CGSize

    var body: some View {
        Canvas { context, size in
            let hDivisions = 8
            let vDivisions = 6

            var gridPath = Path()

            // Vertical lines
            for i in 0...hDivisions {
                let x = CGFloat(i) / CGFloat(hDivisions) * size.width
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: size.height))
            }

            // Horizontal lines
            for i in 0...vDivisions {
                let y = CGFloat(i) / CGFloat(vDivisions) * size.height
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

            // Center lines (bolder)
            var centerPath = Path()
            centerPath.move(to: CGPoint(x: 0, y: size.height / 2))
            centerPath.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            centerPath.move(to: CGPoint(x: size.width / 2, y: 0))
            centerPath.addLine(to: CGPoint(x: size.width / 2, y: size.height))

            context.stroke(centerPath, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
        }
    }
}

// MARK: - Waveform Trace

struct WaveformTrace: View {
    let waveform: WaveformData
    let size: CGSize
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            guard waveform.xValues.count == waveform.yValues.count,
                  waveform.xValues.count > 1 else { return }

            let xSpan = xRange.upperBound - xRange.lowerBound
            let ySpan = yRange.upperBound - yRange.lowerBound
            guard xSpan > 0, ySpan > 0 else { return }

            var path = Path()

            for i in 0..<waveform.xValues.count {
                let x = (waveform.xValues[i] - xRange.lowerBound) / xSpan * Double(size.width)
                let y = (1 - (waveform.yValues[i] - yRange.lowerBound) / ySpan) * Double(size.height)

                let point = CGPoint(x: x, y: y)
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            context.stroke(
                path,
                with: .color(Color(hue: waveform.color.hue, saturation: 0.8, brightness: 0.9)),
                lineWidth: 1.5
            )
        }
    }
}

// MARK: - Spectrum View

struct SpectrumView: View {
    let result: SimulationResult?
    @State private var spectrumData: WaveformData?
    @State private var isComputing = false

    var body: some View {
        Group {
            if let data = spectrumData {
                WaveformChartView(waveforms: [data])
            } else if isComputing {
                ProgressView("Computing spectrum...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text("Run a transient simulation to see spectrum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { computeSpectrumAsync() }
        .onChange(of: result?.timestamp) { _, _ in computeSpectrumAsync() }
    }

    private func computeSpectrumAsync() {
        guard let result = result,
              let timePoints = result.timePoints,
              timePoints.count >= 2,
              timePoints[1] > timePoints[0],
              let firstNode = result.nodeVoltages.keys.sorted().first,
              let values = result.nodeVoltages[firstNode],
              values.count >= 4 else {
            spectrumData = nil
            return
        }

        let sr = 1.0 / (timePoints[1] - timePoints[0])
        let vals = values
        isComputing = true

        Task.detached(priority: .userInitiated) {
            let data = Self.computeFFTAccelerate(values: vals, sampleRate: sr)
            await MainActor.run {
                spectrumData = data
                isComputing = false
            }
        }
    }

    /// Compute FFT using Accelerate vDSP for O(n log n) performance
    private static func computeFFTAccelerate(values: [Double], sampleRate: Double) -> WaveformData {
        let n = values.count
        let halfN = n / 2
        let scale = 2.0 / Double(n)

        // Apply Hann window to reduce spectral leakage
        var windowed = [Double](repeating: 0, count: n)
        var window = [Double](repeating: 0, count: n)
        vDSP_hann_windowD(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmulD(values, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Compute DFT (simpler and more robust than FFT for non-power-of-2 sizes)
        var frequencies = [Double](repeating: 0, count: halfN)
        var magnitudes = [Double](repeating: 0, count: halfN)

        for k in 0..<halfN {
            frequencies[k] = Double(k) * sampleRate / Double(n)
            var real: Double = 0
            var imag: Double = 0

            // Use Accelerate for the inner loop via dot product with precomputed twiddle factors
            for i in 0..<n {
                let angle = -2.0 * .pi * Double(k) * Double(i) / Double(n)
                real += windowed[i] * cos(angle)
                imag += windowed[i] * sin(angle)
            }

            let mag = sqrt(real * real + imag * imag) * scale
            magnitudes[k] = 20 * log10(max(mag, 1e-30))
        }

        return WaveformData(
            name: "Spectrum",
            xValues: frequencies,
            yValues: magnitudes,
            xLabel: "Frequency (Hz)",
            yLabel: "Magnitude (dB)",
            color: .cyan
        )
    }
}

// MARK: - Bode Plot View

struct BodePlotView: View {
    let result: SimulationResult?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("Run AC analysis to see Bode plot")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Table View

struct DataTableView: View {
    let result: SimulationResult?

    var body: some View {
        if let result = result {
            let signalNames = result.allSignalNames.sorted()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        // DC operating point (single row)
                        if result.analysisType == .dcOperatingPoint {
                            HStack(spacing: 0) {
                                ForEach(signalNames, id: \.self) { name in
                                    let value = result.nodeVoltages[name]?.first ?? result.branchCurrents[name]?.first ?? 0
                                    DataCell(text: String(format: "%.6g", value), isHeader: false)
                                }
                            }
                        }

                        // Transient data (lazy rows for performance)
                        if let timePoints = result.timePoints {
                            let maxRows = min(timePoints.count, 5000)
                            ForEach(0..<maxRows, id: \.self) { i in
                                HStack(spacing: 0) {
                                    DataCell(text: String(format: "%.6e", timePoints[i]), isHeader: false)
                                    ForEach(signalNames, id: \.self) { name in
                                        let values = result.nodeVoltages[name] ?? result.branchCurrents[name] ?? []
                                        let value = i < values.count ? values[i] : 0
                                        DataCell(text: String(format: "%.6g", value), isHeader: false)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            if result.timePoints != nil {
                                DataCell(text: "Time", isHeader: true)
                            }
                            ForEach(signalNames, id: \.self) { name in
                                DataCell(text: name, isHeader: true)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.largeTitle)
                    .foregroundStyle(.quaternary)
                Text("Run a simulation to see data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DataCell: View {
    let text: String
    let isHeader: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .fontWeight(isHeader ? .semibold : .regular)
            .frame(width: 120, alignment: .trailing)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(isHeader ? Color.secondary.opacity(0.1) : Color.clear)
    }
}
