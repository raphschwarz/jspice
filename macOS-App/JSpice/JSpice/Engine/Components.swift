import Foundation

// MARK: - Resistor

struct MNAResistor: MNAComponent {
    let name: String
    let nodes: [String]
    let resistance: Double
    let isNonlinear = false
    let requiresExtraEquation = false

    var node1: String { nodes[0] }
    var node2: String { nodes[1] }
    var conductance: Double { 1.0 / max(resistance, 1e-12) }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        stampConductance(conductance, node1: node1, node2: node2, matrix: &matrix, nodeMap: nodeMap)
    }
}

// MARK: - Capacitor (Companion Model — Trapezoidal)

struct MNACapacitor: MNAComponent {
    let name: String
    let nodes: [String]
    let capacitance: Double
    let isNonlinear = false
    let requiresExtraEquation = false

    var timeStep: Double = 1e-6
    var previousVoltage: Double = 0
    var previousCurrent: Double = 0

    var node1: String { nodes[0] }
    var node2: String { nodes[1] }

    /// Trapezoidal companion: Geq = 2C/dt, Ieq = -Geq*Vprev - Iprev
    /// Derivation: I(n+1) = (2C/h)*[V(n+1) - V(n)] - I(n)
    ///           = Geq*V(n+1) + [-Geq*V(n) - I(n)]
    var companionConductance: Double { 2.0 * capacitance / timeStep }
    var companionCurrent: Double { -(companionConductance * previousVoltage) - previousCurrent }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let geq = companionConductance
        let ieq = companionCurrent

        stampConductance(geq, node1: node1, node2: node2, matrix: &matrix, nodeMap: nodeMap)
        stampCurrentSource(ieq, fromNode: node1, toNode: node2, rhs: &rhs, nodeMap: nodeMap)
    }
}

// MARK: - Inductor (Companion Model — Trapezoidal)

struct MNAInductor: MNAComponent {
    let name: String
    let nodes: [String]
    let inductance: Double
    let isNonlinear = false
    let requiresExtraEquation = false

    var timeStep: Double = 1e-6
    var previousVoltage: Double = 0
    var previousCurrent: Double = 0

    var node1: String { nodes[0] }
    var node2: String { nodes[1] }

    /// Trapezoidal companion: Geq = dt/(2L), Ieq = Iprev + Geq*Vprev
    /// Derivation: I(n+1) = I(n) + (h/2L)*[V(n+1) + V(n)]
    ///           = Geq*V(n+1) + [I(n) + Geq*V(n)]
    var companionConductance: Double { timeStep / (2.0 * max(inductance, 1e-18)) }
    var companionCurrent: Double { previousCurrent + companionConductance * previousVoltage }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let geq = companionConductance
        let ieq = companionCurrent

        stampConductance(geq, node1: node1, node2: node2, matrix: &matrix, nodeMap: nodeMap)
        // Current source direction: ieq flows from node1 to node2 (same as inductor current)
        stampCurrentSource(ieq, fromNode: node1, toNode: node2, rhs: &rhs, nodeMap: nodeMap)
    }
}

// MARK: - DC Voltage Source

struct MNADCVoltageSource: MNAComponent {
    let name: String
    let nodes: [String]
    let voltage: Double
    let isNonlinear = false
    let requiresExtraEquation = true

    var positiveNode: String { nodes[0] }
    var negativeNode: String { nodes[1] }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        guard let vsIndex = vsMap[name] else { return }
        let ni = nodeIndex(positiveNode, nodeMap: nodeMap)
        let nj = nodeIndex(negativeNode, nodeMap: nodeMap)

        // Voltage constraint: V+ - V- = voltage
        if let ni = ni {
            matrix[ni, vsIndex] += 1
            matrix[vsIndex, ni] += 1
        }
        if let nj = nj {
            matrix[nj, vsIndex] -= 1
            matrix[vsIndex, nj] -= 1
        }
        rhs[vsIndex] = voltage
    }
}

// MARK: - DC Current Source

struct MNADCCurrentSource: MNAComponent {
    let name: String
    let nodes: [String]
    let current: Double
    let isNonlinear = false
    let requiresExtraEquation = false

    var positiveNode: String { nodes[0] }
    var negativeNode: String { nodes[1] }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        stampCurrentSource(current, fromNode: positiveNode, toNode: negativeNode, rhs: &rhs, nodeMap: nodeMap)
    }
}

// MARK: - Time-Varying Voltage Source

struct MNAACVoltageSource: MNAComponent {
    let name: String
    let nodes: [String]
    let isNonlinear = false
    let requiresExtraEquation = true

    var dcOffset: Double
    var amplitude: Double
    var frequency: Double
    var phase: Double  // radians
    var currentTime: Double = 0

    var positiveNode: String { nodes[0] }
    var negativeNode: String { nodes[1] }

    var instantaneousVoltage: Double {
        dcOffset + amplitude * sin(2.0 * .pi * frequency * currentTime + phase)
    }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        guard let vsIndex = vsMap[name] else { return }
        let ni = nodeIndex(positiveNode, nodeMap: nodeMap)
        let nj = nodeIndex(negativeNode, nodeMap: nodeMap)

        if let ni = ni {
            matrix[ni, vsIndex] += 1
            matrix[vsIndex, ni] += 1
        }
        if let nj = nj {
            matrix[nj, vsIndex] -= 1
            matrix[vsIndex, nj] -= 1
        }
        rhs[vsIndex] = instantaneousVoltage
    }
}

// MARK: - Diode (Shockley model with Newton-Raphson)

struct MNADiode: MNAComponent {
    let name: String
    let nodes: [String]
    let isNonlinear = true
    let requiresExtraEquation = false

    var saturationCurrent: Double = 1e-14
    var emissionCoefficient: Double = 1.0
    var thermalVoltage: Double = 0.02585  // kT/q at 25°C

    var anodeNode: String { nodes[0] }
    var cathodeNode: String { nodes[1] }

    /// SPICE-style voltage limiting to aid Newton-Raphson convergence
    private func limitVoltage(_ vd: Double, vt: Double) -> Double {
        // Limit forward voltage to prevent exp() overflow
        let vCritical = vt * log(vt / (saturationCurrent * sqrt(2.0)))
        if vd > vCritical {
            return vCritical + vt * log(max(1 + (vd - vCritical) / vt, 1e-30))
        }
        return vd
    }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let ni = nodeIndex(anodeNode, nodeMap: nodeMap)
        let nj = nodeIndex(cathodeNode, nodeMap: nodeMap)

        // Get voltage across diode from current solution
        let va = ni.map { solution[$0] } ?? 0
        let vc = nj.map { solution[$0] } ?? 0
        let vd = va - vc

        let vt = emissionCoefficient * thermalVoltage

        // SPICE-style voltage limiting for convergence
        let vdLimited = limitVoltage(vd, vt: vt)

        // Diode current: Id = Is * (exp(Vd/Vt) - 1)
        let expTerm = exp(vdLimited / vt)
        let id = saturationCurrent * (expTerm - 1)

        // Conductance (derivative): Gd = Is/Vt * exp(Vd/Vt)
        let gd = max((saturationCurrent / vt) * expTerm, 1e-12)  // Minimum gmin for convergence

        // Equivalent current for linearized model: Ieq = Id - Gd * Vd
        let ieq = id - gd * vdLimited

        // Stamp conductance
        stampConductance(gd, node1: anodeNode, node2: cathodeNode, matrix: &matrix, nodeMap: nodeMap)

        // Stamp equivalent current source
        stampCurrentSource(ieq, fromNode: anodeNode, toNode: cathodeNode, rhs: &rhs, nodeMap: nodeMap)
    }
}

// MARK: - NPN BJT (Ebers-Moll Transport Model)

struct MNANJPNBJT: MNAComponent {
    let name: String
    let nodes: [String]  // [base, collector, emitter]
    let isNonlinear = true
    let requiresExtraEquation = false

    var beta: Double = 100
    var saturationCurrent: Double = 1e-14
    var thermalVoltage: Double = 0.02585

    var baseNode: String { nodes[0] }
    var collectorNode: String { nodes[1] }
    var emitterNode: String { nodes[2] }

    /// Voltage limiting for BJT junctions
    private func limitJunctionVoltage(_ v: Double) -> Double {
        let vt = thermalVoltage
        let vCritical = vt * log(vt / (saturationCurrent * sqrt(2.0)))
        if v > vCritical {
            return vCritical + vt * log(max(1 + (v - vCritical) / vt, 1e-30))
        }
        return v
    }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let nb = nodeIndex(baseNode, nodeMap: nodeMap)
        let nc = nodeIndex(collectorNode, nodeMap: nodeMap)
        let ne = nodeIndex(emitterNode, nodeMap: nodeMap)

        let vb = nb.map { solution[$0] } ?? 0
        let vc = nc.map { solution[$0] } ?? 0
        let ve = ne.map { solution[$0] } ?? 0

        let vbe = limitJunctionVoltage(vb - ve)
        let vbc = limitJunctionVoltage(vb - vc)

        let vt = thermalVoltage
        let alphaF = beta / (beta + 1)
        let betaR = 1.0  // reverse beta (simplified)
        let alphaR = betaR / (betaR + 1)

        // Junction currents
        let expBE = exp(vbe / vt)
        let expBC = exp(vbc / vt)
        let gmin: Double = 1e-12

        let iF = saturationCurrent * (expBE - 1)
        let iR = saturationCurrent * (expBC - 1)

        // Junction conductances (linearization)
        let gBE = max((saturationCurrent / vt) * expBE, gmin)
        let gBC = max((saturationCurrent / vt) * expBC, gmin)

        // Terminal currents (Ebers-Moll transport model):
        //   Ic = alphaF * iF - iR
        //   Ie = -iF + alphaR * iR
        //   Ib = iF*(1-alphaF) + iR*(1-alphaR) = iF/betaF + iR/betaR
        //
        // We stamp the three terminal currents directly as linearized expressions.
        // Linearized junction currents:
        //   iF ≈ gBE * Vbe + ieqF  where ieqF = iF - gBE * vbe
        //   iR ≈ gBC * Vbc + ieqR  where ieqR = iR - gBC * vbc
        let ieqF = iF - gBE * vbe
        let ieqR = iR - gBC * vbc

        // --- Collector current: Ic = alphaF * (gBE*Vbe + ieqF) - (gBC*Vbc + ieqR) ---
        // = alphaF*gBE*(Vb-Ve) - gBC*(Vb-Vc) + (alphaF*ieqF - ieqR)
        let gmF = alphaF * gBE   // forward transconductance
        let icEq = alphaF * ieqF - ieqR

        // Collector row (current entering collector)
        if let nc = nc, let nb = nb { matrix[nc, nb] += gmF - gBC }
        if let nc = nc, let ne = ne { matrix[nc, ne] -= gmF }
        if let nc = nc              { matrix[nc, nc] += gBC }
        if let nc = nc              { rhs[nc] += icEq }

        // --- Emitter current: Ie = -(gBE*Vbe + ieqF) + alphaR*(gBC*Vbc + ieqR) ---
        // = -gBE*(Vb-Ve) + alphaR*gBC*(Vb-Vc) + (-ieqF + alphaR*ieqR)
        let gmR = alphaR * gBC   // reverse transconductance
        let ieEq = -ieqF + alphaR * ieqR

        // Emitter row (current entering emitter = -Ie leaves emitter)
        if let ne = ne, let nb = nb { matrix[ne, nb] -= gBE - gmR }
        if let ne = ne              { matrix[ne, ne] += gBE }
        if let ne = ne, let nc = nc { matrix[ne, nc] -= gmR }
        if let ne = ne              { rhs[ne] += ieEq }

        // --- Base current: Ib = iF*(1-alphaF) + iR*(1-alphaR) ---
        // This is implicitly satisfied by KCL: Ib = -(Ic + Ie)
        // But we stamp it explicitly for the base row for numerical stability.
        let gbF = (1 - alphaF) * gBE
        let gbR = (1 - alphaR) * gBC
        let ibEq = (1 - alphaF) * ieqF + (1 - alphaR) * ieqR

        if let nb = nb              { matrix[nb, nb] += gbF + gbR }
        if let nb = nb, let ne = ne { matrix[nb, ne] -= gbF }
        if let nb = nb, let nc = nc { matrix[nb, nc] -= gbR }
        if let nb = nb              { rhs[nb] -= ibEq }
    }
}

// MARK: - NMOS (Level 1 — Shichman-Hodges)

struct MNANMOS: MNAComponent {
    let name: String
    let nodes: [String]  // [gate, drain, source]
    let isNonlinear = true
    let requiresExtraEquation = false

    var vth: Double = 0.7       // Threshold voltage
    var kp: Double = 110e-6     // Transconductance parameter
    var channelLength: Double = 1e-6
    var channelWidth: Double = 10e-6
    var lambda: Double = 0.01   // Channel-length modulation

    var gateNode: String { nodes[0] }
    var drainNode: String { nodes[1] }
    var sourceNode: String { nodes[2] }

    var kn: Double { kp * channelWidth / channelLength }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let ng = nodeIndex(gateNode, nodeMap: nodeMap)
        let nd = nodeIndex(drainNode, nodeMap: nodeMap)
        let ns = nodeIndex(sourceNode, nodeMap: nodeMap)

        let vg = ng.map { solution[$0] } ?? 0
        let vd = nd.map { solution[$0] } ?? 0
        let vs = ns.map { solution[$0] } ?? 0

        let vgs = vg - vs
        let vds = vd - vs

        var ids: Double = 0
        var gm: Double = 0    // dId/dVgs
        var gds: Double = 0   // dId/dVds

        if vgs <= vth {
            // Cutoff
            ids = 0
            gm = 0
            gds = 0
        } else if vds < vgs - vth {
            // Linear (triode) region
            let vov = vgs - vth
            ids = kn * (vov * vds - 0.5 * vds * vds) * (1 + lambda * vds)
            gm = kn * vds * (1 + lambda * vds)
            gds = kn * (vov - vds) * (1 + lambda * vds) + kn * (vov * vds - 0.5 * vds * vds) * lambda
        } else {
            // Saturation
            let vov = vgs - vth
            ids = 0.5 * kn * vov * vov * (1 + lambda * vds)
            gm = kn * vov * (1 + lambda * vds)
            gds = 0.5 * kn * vov * vov * lambda
        }

        // Linearized: Ids ≈ ids + gm*(Vgs - vgs) + gds*(Vds - vds)
        // Equivalent current: Ieq = ids - gm*vgs - gds*vds
        let ieq = ids - gm * vgs - gds * vds

        // Stamp transconductance (gate controls drain current)
        if let nd = nd, let ng = ng { matrix[nd, ng] += gm }
        if let nd = nd, let ns = ns { matrix[nd, ns] -= gm }
        if let ns = ns, let ng = ng { matrix[ns, ng] -= gm }
        if let ns = ns           { matrix[ns, ns] += gm }

        // Stamp output conductance
        if let nd = nd { matrix[nd, nd] += gds }
        if let ns = ns { matrix[ns, ns] += gds }
        if let nd = nd, let ns = ns {
            matrix[nd, ns] -= gds
            matrix[ns, nd] -= gds
        }

        // Stamp equivalent current
        if let nd = nd { rhs[nd] += ieq }
        if let ns = ns { rhs[ns] -= ieq }
    }
}

// MARK: - PMOS (Level 1)

struct MNAPMOS: MNAComponent {
    let name: String
    let nodes: [String]  // [gate, drain, source]
    let isNonlinear = true
    let requiresExtraEquation = false

    var vth: Double = -0.7
    var kp: Double = 50e-6
    var channelLength: Double = 1e-6
    var channelWidth: Double = 20e-6
    var lambda: Double = 0.01

    var gateNode: String { nodes[0] }
    var drainNode: String { nodes[1] }
    var sourceNode: String { nodes[2] }

    var kp_eff: Double { kp * channelWidth / channelLength }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let ng = nodeIndex(gateNode, nodeMap: nodeMap)
        let nd = nodeIndex(drainNode, nodeMap: nodeMap)
        let ns = nodeIndex(sourceNode, nodeMap: nodeMap)

        let vg = ng.map { solution[$0] } ?? 0
        let vd = nd.map { solution[$0] } ?? 0
        let vs = ns.map { solution[$0] } ?? 0

        // PMOS: use Vsg, Vsd
        let vsg = vs - vg
        let vsd = vs - vd

        var ids: Double = 0
        var gm: Double = 0
        var gds: Double = 0
        let vthAbs = abs(vth)

        if vsg <= vthAbs {
            ids = 0; gm = 0; gds = 0
        } else if vsd < vsg - vthAbs {
            let vov = vsg - vthAbs
            ids = kp_eff * (vov * vsd - 0.5 * vsd * vsd) * (1 + lambda * vsd)
            gm = kp_eff * vsd * (1 + lambda * vsd)
            gds = kp_eff * (vov - vsd) * (1 + lambda * vsd) + kp_eff * (vov * vsd - 0.5 * vsd * vsd) * lambda
        } else {
            let vov = vsg - vthAbs
            ids = 0.5 * kp_eff * vov * vov * (1 + lambda * vsd)
            gm = kp_eff * vov * (1 + lambda * vsd)
            gds = 0.5 * kp_eff * vov * vov * lambda
        }

        // PMOS current flows from source to drain
        let ieq = ids - gm * vsg - gds * vsd

        // Stamp (reversed polarity from NMOS)
        if let ns = ns, let ng = ng { matrix[ns, ng] -= gm }
        if let ns = ns           { matrix[ns, ns] += gm }
        if let nd = nd, let ng = ng { matrix[nd, ng] += gm }
        if let nd = nd, let ns = ns { matrix[nd, ns] -= gm }

        if let ns = ns { matrix[ns, ns] += gds }
        if let nd = nd { matrix[nd, nd] += gds }
        if let ns = ns, let nd = nd {
            matrix[ns, nd] -= gds
            matrix[nd, ns] -= gds
        }

        if let ns = ns { rhs[ns] -= ieq }
        if let nd = nd { rhs[nd] += ieq }
    }
}

// MARK: - VCVS (Voltage-Controlled Voltage Source)

struct MNAVCVS: MNAComponent {
    let name: String
    let nodes: [String]  // [out+, out-, ctrl+, ctrl-]
    let isNonlinear = false
    let requiresExtraEquation = true

    var gain: Double

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        guard let vsIndex = vsMap[name] else { return }
        let nop = nodeIndex(nodes[0], nodeMap: nodeMap)
        let nom = nodeIndex(nodes[1], nodeMap: nodeMap)
        let ncp = nodeIndex(nodes[2], nodeMap: nodeMap)
        let ncm = nodeIndex(nodes[3], nodeMap: nodeMap)

        // Output voltage constraint: Vout+ - Vout- = gain * (Vctrl+ - Vctrl-)
        if let nop = nop { matrix[vsIndex, nop] += 1; matrix[nop, vsIndex] += 1 }
        if let nom = nom { matrix[vsIndex, nom] -= 1; matrix[nom, vsIndex] -= 1 }
        if let ncp = ncp { matrix[vsIndex, ncp] -= gain }
        if let ncm = ncm { matrix[vsIndex, ncm] += gain }
    }
}

// MARK: - VCCS (Voltage-Controlled Current Source)

struct MNAVCCS: MNAComponent {
    let name: String
    let nodes: [String]  // [out+, out-, ctrl+, ctrl-]
    let isNonlinear = false
    let requiresExtraEquation = false

    var transconductance: Double  // gm

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        let nop = nodeIndex(nodes[0], nodeMap: nodeMap)
        let nom = nodeIndex(nodes[1], nodeMap: nodeMap)
        let ncp = nodeIndex(nodes[2], nodeMap: nodeMap)
        let ncm = nodeIndex(nodes[3], nodeMap: nodeMap)

        // I = gm * (Vctrl+ - Vctrl-)
        if let nop = nop, let ncp = ncp { matrix[nop, ncp] += transconductance }
        if let nop = nop, let ncm = ncm { matrix[nop, ncm] -= transconductance }
        if let nom = nom, let ncp = ncp { matrix[nom, ncp] -= transconductance }
        if let nom = nom, let ncm = ncm { matrix[nom, ncm] += transconductance }
    }
}
