import Foundation

// What the simulator reads out (currents, voltages, power) and records on its scopes, moved out of Simulator.swift
// as it was.

extension Simulator {
    /// The element's main current and the current flowing out of it into each of its terminals
    private func elementCurrents(_ i: Int, _ element: Element, _ v: (Int) -> Double) -> (main: Double, out: [Double]) {
        let nodes = topology.elementNodes[i]
        func twoTerminal(_ current: Double) -> (Double, [Double]) { (current, [-current, current]) }
        switch element.kind {
        case .resistor, .lamp:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) / max(element[param: "resistance"], 1e-9))
        case .potentiometer:
            let (upper, lower) = potentiometerResistances(element)
            let first = (v(nodes[0]) - v(nodes[2])) / upper
            let second = (v(nodes[2]) - v(nodes[1])) / lower
            return (first, [-first, second, first - second])
        case .capacitor:
            return twoTerminal(capacitorCurrent[i])
        case .inductor:
            let saturating = element.saturates && i < constants.count
            return twoTerminal(inductorCurrent[i] + (saturating ? coreCurrent(i, flux: constants[i].value * inductorCurrent[i]).current : 0))
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
            let row = topology.sourceRow[i]
            return twoTerminal(row >= 0 && row < x.count ? x[row] : 0)
        case .currentSource:
            return twoTerminal(constants[i].value)
        case .diode, .led, .zener:
            let d = diodes[i]
            let anode = d.hasSeriesNode ? nodes[2] : nodes[0]
            return twoTerminal(d.current(v(anode) - v(nodes[1]), gmin: Self.junctionGmin).current + junctionCurrent[Self.chargeSlots * i])
        case .memristor:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) * memristorConductance(i, state: memristorStates[i]))
        case .behavioralSource:
            let current = behaviorCurrent(i, v)
            var out = [Double](repeating: 0, count: nodes.count)
            if out.count >= 2 { (out[0], out[1]) = (-current, current) }
            return (current, out)
        case .njfet, .pjfet:
            let j = jfets[i]
            let n = Self.jfetNodes({ nodes[$0] }, j)
            let p = j.polarity
            let r = j.currents(vgs: p * (v(n.g) - v(n.sp)), vgd: p * (v(n.g) - v(n.dp)), gmin: Self.junctionGmin)
            // with the gate charges' charging currents, gate to source and gate to drain
            let k = Self.chargeSlots * i
            let (gs, gd) = (p * (r.cg - r.cgd + junctionCurrent[k]), p * (r.cgd + junctionCurrent[k + 1]))
            let drain = p * r.cdrain - gd
            return (drain, [-(gs + gd), -drain, gs + gd + drain])
        case .nmos, .pmos:
            let f = mosfets[i]
            let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
            let t = f.type
            let r = f.currents(vgs: t * (v(n.g) - v(n.sp)), vds: t * (v(n.dp) - v(n.sp)), vbs: t * (v(n.s) - v(n.sp)),
                               gmin: Self.junctionGmin)
            // with the stored charges' charging currents: bulk to drain and to source, gate to source, drain and bulk
            let k = Self.chargeSlots * i
            let cbd = r.cbd + junctionCurrent[k]
            let (igs, igd, igb) = (junctionCurrent[k + 2], junctionCurrent[k + 3], junctionCurrent[k + 4])
            // into the gate, the drain, and the source with the bulk
            let gate = t * (igs + igd + igb)
            let drain = t * (r.mode * r.cdrain - cbd - igd)
            return (drain, [-gate, -drain, gate + drain])
        case .npn, .pnp:
            let p: Double = element.kind == .npn ? 1 : -1
            let g = bipolar[i]
            let n = Self.bipolarNodes({ nodes[$0] }, g)
            let r = g.currents(vbe: p * (v(n.bp) - v(n.ep)), vbc: p * (v(n.bp) - v(n.cp)), gmin: Self.junctionGmin)
            // with the stored charges' charging currents: base to emitter, base to collector inside and outside the
            // base resistance
            let k = Self.chargeSlots * i
            let (be, bc, bx) = (p * junctionCurrent[k], p * junctionCurrent[k + 1], p * junctionCurrent[k + 2])
            let (ic, ib) = (p * r.cc - bc - bx, p * r.cb + be + bc + bx)
            return (ic, [-ib, -ic, ic + ib])
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
             .levelDetector:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            return (current, [0, 0, current])
        case .springReverb:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            let coil = (v(nodes[0]) - v(nodes[1])) * constants[i].onConductance
            return (current, [-coil, coil, current])
        case .triode, .pentode:
            let tube = constants[i].tube
            let vgk = v(nodes[0]) - v(nodes[2])
            let vpk = v(nodes[1]) - v(nodes[2])
            let ig = tube.grid(vgk: vgk).current
            if element.kind == .pentode, nodes.count > 3 {
                let t = tube.pentode(vgk: vgk, vsk: v(nodes[3]) - v(nodes[2]), vpk: vpk)
                return (t.plate, [-ig, -t.plate, t.plate + t.screen + ig, -t.screen])
            }
            let ip = tube.triode(vgk: vgk, vpk: vpk).current
            return (ip, [-ig, -ip, ip + ig])
        case .transformer:
            // the part itself; its core carries the currents (see `Circuit.expandModels`)
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            let r = constants[i].value
            // out of the core: the secondary's current at s1, back in at s2; the primary's comes in at p1
            return (current, [-r * current, r * current, current, -current])
        case .vactrol:
            let c = constants[i]
            let led = diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: c.saturation, nvt: c.nvt).current
            let ldr = (v(nodes[2]) - v(nodes[3])) * vactrolConductance(i)
            return (led, [-led, led, -ldr, ldr])
        case .ota:
            let supply = constants[i].supply
            let bias = otaBias(i, junction: v(nodes[3]) + supply).current
            let level = constants[i].clampLevel
            let vt = self.vt
            let clampUp = diodeCurrent(v(nodes[2]) - level, saturation: 1e-14, nvt: vt).current
            let clampDown = diodeCurrent(-level - v(nodes[2]), saturation: 1e-14, nvt: vt).current
            let output = bias * tanh((v(nodes[1]) - v(nodes[0])) / (2 * vt)) - clampUp + clampDown
            return (output, [0, 0, output, -bias])
        case .analogSwitch:
            let g = analogSwitchConductance(i, control: v(nodes[2])).conductance
            let current = g * (v(nodes[0]) - v(nodes[1]))
            return (current, [-current, current, 0])
        case .schmittInverter:
            let target = digitalState[i] ? constants[i].supply : 0
            let current = (target - v(nodes[1])) * constants[i].outputConductance
            return (current, [0, current])
        case .unbufferedInverter:
            let current = inverterCurrent(i, vin: v(nodes[0]), vout: v(nodes[1])).current
            return (current, [0, current])
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledSink, .pll:
            // the main current: what the outputs supply (for a gate, what its output puts out; for a TLC5947, what its
            // outputs sink)
            let c = constants[i]
            let kind = element.kind
            var flows = [Double](repeating: 0, count: nodes.count)
            var total = 0.0
            for (k, high) in zip(kind.logicOutputs, Logic.outputs(kind, logicStates[i], function: Int(c.value))) where k < nodes.count {
                flows[k] = ((high ? c.supply : 0) - v(nodes[k])) * c.outputConductance
                total += kind == .logicGate ? flows[k] : max(flows[k], 0)
            }
            if kind == .ledSink {
                total = 0
                for (k, sunk) in sinkCurrents(i, v).enumerated() where 4 + k < nodes.count {
                    flows[4 + k] = -sunk
                    total += sunk
                }
            }
            return (total, flows)
        case .dualDac, .i2sDac, .i2cDac, .codec, .cvDac, .ledDriver:
            // into each analog output from its source behind the output resistance
            var flows = [Double](repeating: 0, count: nodes.count)
            let c = constants[i]
            let state = logicStates[i]
            let outputs: [(Int, Double)]
            switch element.kind {
            case .dualDac:
                outputs = (0...1).map { (4 + $0, Logic.dualDacOutput(state.count, channel: $0, supply: c.supply)) }
            case .i2sDac:
                outputs = [(3, Logic.i2sOutput(Int32(bitPattern: state.latch))), (4, Logic.i2sOutput(Int32(truncatingIfNeeded: state.count)))]
            case .codec:
                outputs = [(8, Logic.codecOutput(Int32(bitPattern: state.latch), c.supply, c.value)),
                           (9, Logic.codecOutput(Int32(truncatingIfNeeded: state.count), c.supply, c.value))]
            case .cvDac:
                outputs = (0..<8).map { (3 + $0, busParts[i].cvDacCodes.count >= 8 ? Double(busParts[i].cvDacCodes[$0]) / 65536 * c.value : 0) }
            case .ledDriver:
                outputs = pwmOutputs(i).enumerated().map { (9 + $0.offset, $0.element ? c.supply : 0) }
            default:
                outputs = [(3, Logic.i2cDacOutput(state.count, supply: c.supply))]
            }
            for (k, target) in outputs where k < nodes.count { flows[k] = (target - v(nodes[k])) * c.outputConductance }
            return (outputs.first.map { flows[$0.0] } ?? 0, flows)
        case .effectsProcessor:
            var flows = [Double](repeating: 0, count: nodes.count)
            guard nodes.count > 5, let processor = effectsProcessors[i] else { return (0, flows) }
            let g = constants[i].outputConductance
            flows[4] = (processor.left - v(nodes[4])) * g
            flows[5] = (processor.right - v(nodes[5])) * g
            return (flows[4], flows)
        case .dac:
            var flows = [Double](repeating: 0, count: nodes.count)
            guard nodes.count > 5 else { return (0, flows) }
            let c = constants[i]
            let target = Logic.dacOutput(logicStates[i].count, reference: v(nodes[4]), supply: c.supply)
            flows[5] = (target - v(nodes[5])) * c.outputConductance
            return (flows[5], flows)
        case .analogMux, .analogSelector:
            // through the channel that is on, into the common terminal
            var flows = [Double](repeating: 0, count: nodes.count)
            guard let channel = Logic.channel(element.kind, logicStates[i]), channel < nodes.count - 1 else { return (0, flows) }
            let current = (v(nodes[channel]) - v(nodes[nodes.count - 1])) * constants[i].onConductance
            flows[channel] = -current
            flows[nodes.count - 1] = current
            return (current, flows)
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103:
            let c = constants[i]
            var flows = [Double](repeating: 0, count: nodes.count)
            var total = 0.0
            if let states = chipPinStates[i] {
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output(let high): flows[pin] = ((high ? c.supply : 0) - v(nodes[pin])) * c.outputConductance
                    case .input(pullUp: true): flows[pin] = (c.supply - v(nodes[pin])) * c.onConductance
                    case .inputPullDown: flows[pin] = -v(nodes[pin]) * c.onConductance
                    case .input: break
                    }
                    total += max(flows[pin], 0)
                }
            }
            // the main current: what the chip supplies through its pins
            return (total, flows)
        case .timer555:
            let (ground, output, control, discharge, supply) = (nodes[0], nodes[2], nodes[4], nodes[6], nodes[7])
            let high = digitalState[i]
            let upper = (v(supply) - v(control)) / 5000
            let lower = (v(control) - v(ground)) / 10_000
            let target = high ? v(supply) - constants[i].highDrop : v(ground) + 0.1
            let out = (target - v(output)) * constants[i].outputConductance
            let dischargeIn = (v(discharge) - v(ground)) * (high ? 1e-9 : constants[i].dischargeConductance)
            var flows = [Double](repeating: 0, count: 8)
            flows[2] = out
            flows[6] = -dischargeIn
            flows[4] = upper - lower
            flows[7] = -upper - (high ? out : 0)
            flows[0] = lower + dischargeIn - (high ? 0 : out)
            return (out, flows)
        default:
            return (0, Array(repeating: 0, count: nodes.count))
        }
    }

    func refreshCurrents() {
        guard currentsAreStale else { return }
        currentsAreStale = false
        computeCurrents()
    }

    private func computeCurrents() {
        let elements = flat.elements
        guard storedCurrents.count == elements.count else { return }
        let hasSolution = x.count == topology.matrixSize
        func v(_ node: Int) -> Double { hasSolution ? voltage(node) : 0 }

        var injection = [Double](repeating: 0, count: topology.points.count)
        for (i, element) in elements.enumerated() {
            if element.isConductor {
                storedCurrents[i] = 0
                continue
            }
            let (main, out) = elementCurrents(i, element, v)
            storedCurrents[i] = main
            for (point, current) in zip(topology.elementPoints[i], out) {
                injection[point] += current
            }
        }
        // wires and other conductors carry what flows into them from the leaves of the wire network inwards
        for step in topology.flowOrder {
            let flow = injection[step.from]
            injection[step.to] += flow
            storedCurrents[step.element] = topology.elementPoints[step.element][0] == step.from ? flow : -flow
        }
    }

    // MARK: - Readings

    public func voltage(at point: GridPoint) -> Double {
        guard let p = topology.pointIndex[point], x.count == topology.matrixSize else { return 0 }
        return voltage(topology.nodeOfPoint[p])
    }

    /// Voltage of each terminal of the element at `index`
    /// Voltage of one terminal of the element at `index`, without building the list of all of them
    public func terminalVoltage(_ index: Int, _ terminal: Int) -> Double {
        guard index < topology.elementNodes.count, x.count == topology.matrixSize else { return 0 }
        let nodes = topology.elementNodes[index]
        return terminal >= 0 && terminal < nodes.count ? voltage(nodes[terminal]) : 0
    }

    public func terminalVoltages(_ index: Int) -> [Double] {
        guard index < topology.elementNodes.count, x.count == topology.matrixSize else { return [] }
        return topology.elementNodes[index].map { voltage($0) }
    }

    /// Voltage across the element: a minus b; for voltage sources + (b) minus - (a), so a 5 V source reads 5 V;
    /// drain minus source (collector minus emitter) for transistors; the output voltage for op-amps
    public func voltageAcross(_ index: Int) -> Double {
        guard index < across.count, x.count == topology.matrixSize else { return 0 }
        switch across[index] {
        case let .nodes(plus, minus): return voltage(plus) - voltage(minus)
        case .supply: return constants[index].supply
        case .nothing: return 0
        }
    }

    func findAcross() {
        across = kinds.indices.map { i -> Across in
            let kind = kinds[i]
            if kind != .behavioralSource && (kind.isMicrocontroller || kind.hasChipPackage) { return .supply }
            guard let (plus, minus) = acrossNodes(i) else { return .nothing }
            return .nodes(plus, minus)
        }
    }

    /// The nodes `voltageAcross` reads, plus then minus (0 is ground); nil for parts it reads no nodes of
    public func acrossNodes(_ index: Int) -> (plus: Int, minus: Int)? {
        guard index < topology.elementNodes.count, index < kinds.count else { return nil }
        let nodes = topology.elementNodes[index]
        if nodes.count == 1 { return (nodes[0], 0) }
        guard nodes.count >= 2 else { return nil }
        let kind = kinds[index]
        if kind.isTransistor || kind.isTube { return (nodes[1], nodes[2]) }
        if kind == .transformer { return nodes.count == 4 ? (nodes[2], nodes[3]) : nil }
        if kind == .ota || kind.drivesOutput { return (nodes[2], 0) }
        if kind == .timer555 { return (nodes[2], nodes[0]) }
        if kind == .behavioralSource { return (nodes[0], nodes[1]) }
        if kind.isMicrocontroller || kind.hasChipPackage || kind == .block { return nil }
        if kind == .schmittInverter || kind == .unbufferedInverter { return (nodes[1], 0) }
        if kind == .logicGate { return (nodes[2], 0) }
        return kind.isVoltageSource ? (nodes[1], nodes[0]) : (nodes[0], nodes[1])
    }

    public func current(_ index: Int) -> Double {
        refreshCurrents()
        return index < storedCurrents.count ? storedCurrents[index] : 0
    }

    public func value(_ quantity: Quantity, of index: Int) -> Double {
        switch quantity {
        case .voltage: return voltageAcross(index)
        case .current: return current(index)
        case .power: return voltageAcross(index) * current(index)
        case .resistance:
            let element = flat.elements[index]
            if element.kind == .memristor { return 1 / memristorConductance(index, state: memristorStates[index]) }
            if element.kind == .resistor || element.kind == .lamp || element.kind == .potentiometer {
                return element[param: "resistance"]
            }
            let i = current(index)
            return abs(i) > 1e-15 ? voltageAcross(index) / i : .infinity
        }
    }

    /// 0 (dark) to 1 (full brightness) for LEDs and lamps (and the Pico's LED)
    public func brightness(_ index: Int) -> Double {
        let element = flat.elements[index]
        switch element.kind {
        case .led:
            return min(1, max(0, current(index) / 0.015))
        case .lamp:
            let power = abs(voltageAcross(index) * current(index))
            return min(1, power / max(element[param: "ratedPower"], 1e-9))
        case .rp2040:
            // the Pico's own LED
            return (chips[index] as? Pico)?.ledOn == true ? 1 : 0
        default:
            return 0
        }
    }

    /// True while a 555's, Schmitt inverter's or logic gate's output is high
    public func isHigh(_ index: Int) -> Bool {
        if index < kinds.count, kinds[index] == .logicGate { return logicOutputs(index).first ?? false }
        return index < digitalState.count ? digitalState[index] : false
    }

    /// Whether each output of a logic part is high, in the order of its output terminals
    public func logicOutputs(_ index: Int) -> [Bool] {
        guard index < kinds.count, index < logicStates.count else { return [] }
        return Logic.outputs(kinds[index], logicStates[index], function: Int(constants[index].value))
    }

    /// A counter's count, a flip-flop's Q (1 or 0), or the channel a multiplexer has on (-1 while inhibited)
    public func logicCount(_ index: Int) -> Int {
        guard index < kinds.count, index < logicStates.count else { return 0 }
        if kinds[index] == .analogMux || kinds[index] == .analogSelector { return Logic.channel(kinds[index], logicStates[index]) ?? -1 }
        return logicStates[index].count
    }

    /// An SPI ADC's last conversion (0 to 1023)
    public func adcReading(_ index: Int) -> Int {
        guard index < kinds.count, index < logicStates.count, kinds[index] == .spiAdc else { return 0 }
        return Int(logicStates[index].latch)
    }

    /// 0 (open) to 1 (closed) for analog switches
    public func switchConduction(_ index: Int) -> Double {
        guard index < flat.elements.count, flat.elements[index].kind == .analogSwitch else { return 0 }
        let v = terminalVoltages(index)
        guard v.count == 3 else { return 0 }
        let g = analogSwitchConductance(index, control: v[2]).conductance
        return min(1, g / constants[index].onConductance)
    }

    /// 0 (fully off) to 1 (fully on)
    public func memristorState(_ index: Int) -> Double {
        index < memristorStates.count ? memristorStates[index] : 0
    }

    public var nodeCount: Int { topology.nodeCount }

    /// The equations' size: unknowns, entries that can be non-zero, entries of the factors (fill-in included), and the
    /// unknowns in the nonlinear block, which Newton-Raphson refactors
    public var equationStatistics: (unknowns: Int, nonzeros: Int, factorEntries: Int, nonlinearUnknowns: Int) {
        let m = topology.matrixSize
        guard let plan else { return (m, 0, 0, 0) }
        let nonzeros = plan.structure.reduce(0) { $1 ? $0 + 1 : $0 }
        return (m, nonzeros, plan.entryCount, plan.n - plan.leading)
    }

    /// The nonlinear block's factors as last factored: entries of L and U, and the multiply-adds of factoring
    public var blockFactorSize: (lower: Int, upper: Int, operations: Int) {
        plan?.blockFactorSize ?? (0, 0, 0)
    }

    /// The levels back substitution goes through in the nonlinear and the linear block, and their steps: how long the
    /// chain of rows each waits on is
    public var substitutionLevels: (block: Int, blockSteps: Int, linear: Int, linearSteps: Int) {
        plan?.substitutionLevels ?? (0, 0, 0, 0)
    }

    /// Pivot orders the plan has for its nonlinear block (one for each state its parts have been seen in, up to a few)
    public var pivotOrders: Int {
        plan?.orderCount ?? 0
    }

    /// The index of a part of the circuit as it is simulated: one of the circuit's own, or one inside a block (by its
    /// id there, `UUID.inBlock`)
    public func flatIndex(of id: UUID) -> Int? {
        flat.elements.firstIndex { $0.id == id }
    }

    /// Node number of each terminal of the element at `index` (0 is ground)
    public func nodes(of index: Int) -> [Int] {
        index < topology.elementNodes.count ? topology.elementNodes[index] : []
    }

    /// The voltage of node `node` (0 is ground)
    public func nodeVoltage(_ node: Int) -> Double {
        node > 0 && node - 1 < x.count && x.count == topology.matrixSize ? x[node - 1] : 0
    }

    /// The largest node voltage magnitude, for scaling voltage colours
    public var maxNodeVoltage: Double {
        guard x.count == topology.matrixSize else { return 0 }
        var result = 0.0
        for node in 1..<max(1, topology.nodeCount) { result = max(result, abs(x[node - 1])) }
        return result
    }

    // MARK: - Scopes

    /// Keeps a trace for every scope of the circuit, each showing the last `window` seconds of circuit time
    public func configureScopes(window: Double) {
        var next: [UUID: ScopeTrace] = [:]
        for spec in circuit.scopes {
            if let existing = traces[spec.id], existing.spec == spec, existing.window == window {
                next[spec.id] = existing
            } else {
                next[spec.id] = ScopeTrace(spec: spec, window: window)
            }
        }
        traces = next
        recordedTraces = circuit.scopes.compactMap { spec in
            // a frequency response is worked out when shown, not recorded
            guard spec.plot != .frequencyResponse, let trace = next[spec.id], let index = circuit.index(of: spec.elementID) else { return nil }
            return (trace, index)
        }
    }

    public func trace(_ id: UUID) -> ScopeTrace? { traces[id] }

    func record(_ trace: ScopeTrace, _ index: Int) {
        func scoped() -> Double {
            switch trace.spec.quantity {
            case .current: return scopedCurrent(index)
            case .power: return voltageAcross(index) * scopedCurrent(index)
            default: return value(trace.spec.quantity, of: index)
            }
        }
        switch trace.spec.plot {
        case .time:
            trace.add(scoped(), at: time)
        case .spectrum:
            trace.addSample(scoped(), at: time)
        case .currentVersusVoltage:
            trace.addPoint(voltage: voltageAcross(index), current: scopedCurrent(index), at: time)
        case .frequencyResponse:
            break
        }
    }

    /// One element's current for a scope at every step, without working out the whole circuit's: only wires and
    /// other conductors need the walk through the wire network
    private func scopedCurrent(_ index: Int) -> Double {
        // the commonest parts on a scope read straight from the solution, as `elementCurrents` reads them, without
        // copying the part or making the array of its terminals' currents at every step
        if index < kinds.count, index < topology.elementNodes.count {
            switch kinds[index] {
            case .capacitor:
                return capacitorCurrent[index]
            case .diode, .led, .zener:
                let nodes = topology.elementNodes[index]
                let anode = diodes[index].hasSeriesNode ? nodes[2] : nodes[0]
                return diodes[index].current(voltage(anode) - voltage(nodes[1]), gmin: Self.junctionGmin).current
                    + junctionCurrent[Self.chargeSlots * index]
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
                let row = topology.sourceRow[index]
                return row >= 0 && row < x.count ? x[row] : 0
            case .currentSource:
                return constants[index].value
            default:
                break
            }
        }
        let element = flat.elements[index]
        if element.isConductor { return current(index) }
        return elementCurrents(index, element) { self.voltage($0) }.main
    }
}

/// Recent history of one scope: min/max buckets of a quantity over time (so fast signals still show their envelope),
/// or voltage-current points for an I–V curve.
public final class ScopeTrace {
    public let spec: ScopeSpec
    public let window: Double
    public static let capacity = 600

    public private(set) var minimums: [Double] = []
    public private(set) var maximums: [Double] = []
    public private(set) var lastValue: Double = 0
    /// I–V curve points, oldest first
    public private(set) var voltages: [Double] = []
    public private(set) var currents: [Double] = []
    public private(set) var lastVoltage: Double = 0
    private var bucketStart = 0.0
    private var bucketMin = Double.infinity
    private var bucketMax = -Double.infinity
    /// For a spectrum: the newest `spectrumLength` values at even intervals (between steps, on the line joining them)
    private var ring: [Double] = []
    private var ringNext = 0
    private var ringCount = 0
    private var nextTick = 0.0
    private var previousTime = 0.0
    private var previousValue = 0.0
    private var sampling = false
    /// The simulation's recent step, on average: the spectrum shows nothing faster than it can follow
    private var averageStep = 0.0

    /// Samples a spectrum is worked out from: eight windows' worth, 2048 a window
    public static let spectrumLength = 16_384

    init(spec: ScopeSpec, window: Double) {
        self.spec = spec
        self.window = max(window, 1e-12)
        if spec.plot == .spectrum { ring = [Double](repeating: 0, count: Self.spectrumLength) }
    }

    /// Seconds between a spectrum's samples
    public var sampleInterval: Double { window / 2048 }

    var interval: Double { window / Double(Self.capacity) }

    /// Copies another trace's history
    func adopt(_ other: ScopeTrace) {
        Simulator.adopt(&minimums, other.minimums)
        Simulator.adopt(&maximums, other.maximums)
        lastValue = other.lastValue
        Simulator.adopt(&voltages, other.voltages)
        Simulator.adopt(&currents, other.currents)
        lastVoltage = other.lastVoltage
        bucketStart = other.bucketStart
        bucketMin = other.bucketMin
        bucketMax = other.bucketMax
        Simulator.adopt(&ring, other.ring)
        ringNext = other.ringNext
        ringCount = other.ringCount
        nextTick = other.nextTick
        previousTime = other.previousTime
        previousValue = other.previousValue
        sampling = other.sampling
        averageStep = other.averageStep
    }

    func clear() {
        minimums.removeAll()
        maximums.removeAll()
        voltages.removeAll()
        currents.removeAll()
        lastValue = 0
        lastVoltage = 0
        bucketStart = 0
        bucketMin = .infinity
        bucketMax = -.infinity
        ringNext = 0
        ringCount = 0
        sampling = false
        averageStep = 0
    }

    /// Records a value for a spectrum: one sample at each tick of `sampleInterval` passed since the last value,
    /// on the line from it
    func addSample(_ value: Double, at time: Double) {
        guard value.isFinite, !ring.isEmpty else { return }
        lastValue = value
        let interval = sampleInterval
        if !sampling || time < previousTime {
            sampling = true
            ringNext = 0
            ringCount = 0
            averageStep = 0
            nextTick = time
        } else {
            let step = time - previousTime
            if step > 0 { averageStep = averageStep == 0 ? step : averageStep * 0.98 + step * 0.02 }
        }
        // after a long gap only the newest ring's worth matters
        if (time - nextTick) / interval > Double(ring.count) { nextTick = time - Double(ring.count - 1) * interval }
        let span = time - previousTime
        while nextTick <= time {
            let f = span > 0 ? min(max((nextTick - previousTime) / span, 0), 1) : 1
            ring[ringNext] = previousValue + (value - previousValue) * f
            ringNext = (ringNext + 1) % ring.count
            ringCount = min(ringCount + 1, ring.count)
            nextTick += interval
        }
        previousTime = time
        previousValue = value
    }

    /// The spectrum's samples, oldest first
    public var evenSamples: [Double] {
        guard ringCount > 0 else { return [] }
        let start = (ringNext - ringCount + ring.count) % ring.count
        return (0..<ringCount).map { ring[(start + $0) % ring.count] }
    }

    /// The spectrum of the recent samples, up to the highest frequency both the sampling and the simulation's steps
    /// show; nil until there are enough
    public func spectrum() -> Spectrum? {
        let top = averageStep > 0 ? 0.5 / averageStep : .infinity
        return Spectrum.analyze(evenSamples, interval: sampleInterval, maxFrequency: top)
    }

    func add(_ value: Double, at time: Double) {
        guard value.isFinite else { return }
        lastValue = value
        bucketMin = min(bucketMin, value)
        bucketMax = max(bucketMax, value)
        if time - bucketStart >= interval {
            minimums.append(bucketMin)
            maximums.append(bucketMax)
            if minimums.count > Self.capacity {
                minimums.removeFirst(minimums.count - Self.capacity)
                maximums.removeFirst(maximums.count - Self.capacity)
            }
            bucketStart = time
            bucketMin = .infinity
            bucketMax = -.infinity
        }
    }

    func addPoint(voltage: Double, current: Double, at time: Double) {
        guard voltage.isFinite, current.isFinite else { return }
        lastValue = current
        lastVoltage = voltage
        if time - bucketStart >= interval {
            voltages.append(voltage)
            currents.append(current)
            if voltages.count > Self.capacity {
                voltages.removeFirst(voltages.count - Self.capacity)
                currents.removeFirst(currents.count - Self.capacity)
            }
            bucketStart = time
        }
    }
}
