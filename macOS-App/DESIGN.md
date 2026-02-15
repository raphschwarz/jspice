# JSpice for macOS — Design Document

## Vision

JSpice for macOS is a native analog circuit simulator that combines professional-grade SPICE simulation with an Apple-quality user experience. It targets audio engineers, students, and analog designers who need real-time, interactive circuit prototyping with a focus on audio circuits.

**Design Philosophy:** Logic Pro meets circuit simulation — simple enough for students, powerful enough for professional audio engineers and analog designers.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    SwiftUI Interface                      │
│  ┌──────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │ Component │  │  Schematic Editor │  │  Inspector   │  │
│  │ Library   │  │  (Metal Canvas)   │  │  Panel       │  │
│  └──────────┘  └──────────────────┘  └──────────────┘  │
│  ┌──────────────────────────────────────────────────┐   │
│  │         Waveform Viewer / Spectrum View           │   │
│  └──────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                   Domain Layer                           │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐   │
│  │  Circuit     │  │  Netlist   │  │  Project       │   │
│  │  Document    │  │  Generator │  │  Manager       │   │
│  └─────────────┘  └────────────┘  └────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                  Simulation Engine                        │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐   │
│  │  MNA Solver  │  │  Newton-   │  │  Transient     │   │
│  │  (Accelerate)│  │  Raphson   │  │  Integration   │   │
│  └─────────────┘  └────────────┘  └────────────────┘   │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐   │
│  │  DC Op Point │  │  AC/Freq   │  │  Signal        │   │
│  │  Analysis    │  │  Analysis  │  │  Generators    │   │
│  └─────────────┘  └────────────┘  └────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                    Audio Engine                           │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐   │
│  │  Core Audio  │  │  Real-time │  │  Audio Buffer  │   │
│  │  Output      │  │  Render    │  │  Manager       │   │
│  └─────────────┘  └────────────┘  └────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer              | Technology                         | Rationale                                              |
|--------------------|------------------------------------|--------------------------------------------------------|
| UI Framework       | SwiftUI + AppKit (hybrid)          | Modern declarative UI with AppKit for canvas rendering  |
| Canvas Rendering   | Metal via MTKView                  | GPU-accelerated schematic rendering, smooth pan/zoom    |
| Linear Algebra     | Accelerate (LAPACK/BLAS)           | Apple Silicon optimized matrix operations               |
| Audio              | Core Audio (AudioUnit)             | Low-latency real-time audio output                      |
| Persistence        | Codable + JSON/YAML                | Native Swift serialization                              |
| Charting           | Custom Metal/Core Graphics         | Waveform viewer with 60fps rendering                    |
| Concurrency        | Swift Concurrency (async/await)    | Modern threading for simulation off main thread         |
| Build              | Swift Package Manager + Xcode      | Native Apple toolchain                                  |

### Why Swift-native SPICE (not wrapping ngspice)?

1. **Accelerate framework** gives us LAPACK/BLAS optimized for Apple Silicon — faster than generic C libraries
2. **No FFI boundary** — direct memory access, no marshaling overhead for real-time audio
3. **Tight integration** — simulation state directly drives UI without serialization
4. **The existing JSpice codebase** provides clear MNA algorithm reference to port from

---

## Data Model

### Core Types

```swift
// Circuit element identification
struct NodeID: Hashable, Codable { let name: String }
struct ComponentID: Hashable, Codable { let uuid: UUID }

// Base component protocol
protocol CircuitComponent: Identifiable, Codable {
    var id: ComponentID { get }
    var nodes: [NodeID] { get }
    var parameters: [String: Double] { get set }

    // MNA stamp
    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector)
}

// Circuit document
struct CircuitDocument: Codable {
    var components: [any CircuitComponent]
    var wires: [Wire]
    var metadata: ProjectMetadata
}

// Wire connection
struct Wire: Identifiable, Codable {
    let id: UUID
    var startNode: NodeID
    var endNode: NodeID
    var waypoints: [CGPoint]
}
```

### Component Hierarchy

```
CircuitComponent (protocol)
├── LinearComponent
│   ├── Resistor
│   ├── Capacitor (companion model)
│   └── Inductor (companion model)
├── NonlinearComponent
│   ├── Diode (Newton-Raphson)
│   ├── BJT (Ebers-Moll / Gummel-Poon)
│   ├── MOSFET (Level 1/2/3)
│   └── OpAmp (macro model)
├── SourceComponent
│   ├── DCVoltageSource
│   ├── DCCurrentSource
│   ├── ACVoltageSource
│   ├── VCVS, VCCS, CCVS, CCCS
│   └── SignalGenerator (sine, square, triangle, sawtooth, pulse)
└── SubCircuit
    └── Custom grouped components
```

---

## Simulation Engine Design

### Modified Nodal Analysis (MNA)

The core solver uses MNA identical to the JSpice reference implementation:

```
[G  B] [v]   [i]
[C  D] [j] = [e]

Where:
  G = conductance matrix (n×n)
  B = voltage source coupling
  C = transpose coupling
  D = dependent source matrix
  v = node voltages (unknowns)
  j = branch currents (unknowns)
  i = current source vector
  e = voltage source vector
```

**Solver:** LU decomposition via Accelerate's `dgesv_` (LAPACK)

### Analysis Types

1. **DC Operating Point** — Single-point MNA solve with Newton-Raphson for nonlinear elements
2. **DC Sweep** — Parametric sweep of a source value, solving at each step
3. **Transient Analysis** — Time-domain using trapezoidal integration (companion models for C/L)
4. **AC Analysis** — Small-signal frequency response using complex MNA
5. **FFT/Spectrum** — Accelerate's vDSP FFT on transient results

### Threading Model

```
Main Thread (UI)
    │
    ├── Simulation Actor (isolated)
    │   ├── Solver runs on high-priority queue
    │   ├── Results published via AsyncStream
    │   └── Cancellable on parameter change
    │
    └── Audio Render Thread (real-time)
        ├── Highest priority, no allocations
        ├── Reads from lock-free ring buffer
        └── Fed by simulation actor
```

---

## Audio Engine Design

### Real-time Pipeline

```
Simulation Actor
    │ (produces samples at circuit sample rate)
    ▼
Lock-free Ring Buffer (TPCircularBuffer pattern)
    │
    ▼
Audio Render Callback (Core Audio IOProc)
    │ (consumes at audio hardware rate, e.g., 48kHz)
    ▼
Core Audio Output (speakers/headphones)
```

### Key Constraints
- Audio callback must NEVER allocate memory or lock
- Ring buffer provides decoupling between simulation and audio threads
- Sample rate conversion if simulation rate ≠ audio rate
- Target latency: 256-512 samples (~5-10ms at 48kHz)

---

## UI/UX Design

### Layout

```
┌──────────┬────────────────────────────┬──────────────┐
│          │                            │              │
│ Component│    Schematic Canvas        │  Inspector   │
│ Library  │    (infinite, zoomable)    │  Panel       │
│          │                            │              │
│ - Search │    Metal-rendered          │ - Properties │
│ - Categories│ Snap-to-grid           │ - Parameters │
│ - Favorites│  Wire routing           │ - Model Info │
│          │                            │              │
├──────────┴────────────────────────────┴──────────────┤
│                                                       │
│  Waveform Viewer / Oscilloscope / Spectrum            │
│  (resizable, like DAW timeline)                       │
│                                                       │
└───────────────────────────────────────────────────────┘
```

### Visual Language
- **SF Pro** typography throughout
- **Frosted glass** sidebar panels (`.ultraThinMaterial`)
- **Subtle shadows** on components
- **Accent color** for selected elements and active signals
- **Dark/Light** mode with semantic colors
- **Smooth animations** on all state transitions (spring curves)
- **Live signal visualization** on wires (optional glow effect)

---

## Development Roadmap

### Phase 1 — MVP (Core Simulation + Basic UI)
- Swift SPICE engine: MNA solver, DC operating point
- Basic components: R, C, L, V, I sources
- Schematic editor: place components, draw wires
- Simple waveform display
- Transient analysis with basic drivers
- Project save/load

### Phase 2 — Interactive Simulation
- Nonlinear components: Diode, BJT, MOSFET
- AC analysis + Bode plots
- Signal generators (sine, square, triangle, sawtooth)
- Live re-simulation on parameter change
- Inspector panel with real-time parameter editing
- FFT spectrum view
- Component library with search

### Phase 3 — Audio & Professional
- Core Audio real-time output
- Audio-focused components (op-amp, filters)
- Monte Carlo analysis
- Temperature sweep
- Noise analysis
- SPICE netlist import/export
- Custom SPICE model import
- Export plots as PDF/PNG/CSV

### Phase 4 — Polish & Advanced
- Metal-rendered schematic canvas
- Wire signal visualization
- Subcircuit creation and reuse
- Manufacturer part database
- iCloud sync
- Keyboard shortcuts and power-user workflows

---

## Differentiation vs. Competitors

| Feature              | LTspice  | Multisim | Falstad  | JSpice macOS     |
|----------------------|----------|----------|----------|------------------|
| macOS Native         | Wine/Old | No       | Web      | **Yes, optimized** |
| Real-time Audio      | No       | No       | Limited  | **Yes, Core Audio** |
| Apple Silicon Opt.   | No       | No       | N/A      | **Accelerate/Metal** |
| Modern UI/UX         | 1990s    | Windows  | Basic    | **Apple-quality**   |
| Audio Circuit Focus  | General  | General  | General  | **Primary focus**   |
| Live Re-simulation   | Manual   | Manual   | Yes      | **Yes, smooth**     |
| Beginner Friendly    | No       | Moderate | Yes      | **Yes + powerful**  |
