import Foundation

/// A junction field-effect transistor as SPICE models it: ngspice's level 1, the Shichman-Hodges model with the
/// University of Sydney's doping-tail parameter B, with the parameters of a `.model` card. Its equations are ngspice's
/// (`jfettemp.c` and `jfetload.c`): the channel current with channel-length modulation, the two gate junctions, the
/// drain and source resistances on internal nodes, the gate-source and gate-drain depletion charges, and the
/// temperature of the threshold, the transconductance and the gate's saturation current. `crosscheck.py` checks it.
///
/// A drawn JFET is set by its pinch-off voltage and IDSS, the drain current with the gate at the source in saturation;
/// a card's BETA is IDSS over the pinch-off voltage squared (with B at 1). Not modelled: PSpice's extensions (the gate
/// junction's N and grading M, ISR and NR, ALPHA and VK), and flicker noise.
struct SpiceJFET {
    /// 1 for N-channel, −1 for P-channel: the voltages in the transistor's own polarity are this times the circuit's
    var polarity = 1.0
    /// Parameters as worked out at the circuit's temperature
    var threshold = -2.0, beta = 1e-4, lambda = 0.0
    var b = 1.0, bFactor = 0.0
    var rd = 0.0, rs = 0.0
    var saturation = 1e-14
    /// Depletion capacitances at zero bias, the gate potential, and the straight continuation above FC times it
    var cgs = 0.0, cgd = 0.0, pb = 1.0, fcv = 0.5, f1 = 0.0, f2 = 1.0, f3 = 1.0
    var kf = 0.0, af = 1.0
    var vt = Simulator.thermalVoltage
    /// The junction voltage above which SPICE limits Newton-Raphson's steps
    var critical = 0.0

    /// Whether the drain and source have internal nodes (their resistances are not zero), in that order after the
    /// three terminals
    var hasDrainNode: Bool { rd > 0 }
    var hasSourceNode: Bool { rs > 0 }
    var hasCharges: Bool { cgs > 0 || cgd > 0 }

    /// The internal nodes a JFET with these parameters has
    static func internalNodes(_ element: Element) -> Int {
        (element[param: "rd"] > 0 ? 1 : 0) + (element[param: "rs"] > 0 ? 1 : 0)
    }

    struct Currents {
        /// Into the gate through both junctions, and through the gate-drain junction alone (from gate to drain)
        var cg = 0.0, cgd = 0.0
        var ggs = 0.0, ggd = 0.0
        /// The channel's current from drain to source, and its slopes in vgs and vds
        var cdrain = 0.0, gm = 0.0, gds = 0.0
    }

    struct Charges {
        var qgs = 0.0, capgs = 0.0, qgd = 0.0, capgd = 0.0
    }

    init() {}

    /// The card of `element` at `kelvin`, where the thermal voltage is `vt`
    init(_ element: Element, kelvin: Double, vt: Double) {
        func p(_ key: String) -> Double {
            let value = element[param: key]
            return value.isFinite ? value : 0
        }
        self.vt = vt
        polarity = element.kind == .pjfet ? -1 : 1
        let tnom = Simulator.nominalKelvin
        let boltzmann = 1.38064852e-23, charge = 1.6021766208e-19, reference = 300.15
        // the nominal card: the threshold and B set how BETA relates to IDSS
        let vto = Self.pinchOff(element)
        b = p("b") > 0 ? p("b") : 1
        let nominalPotential = max(p("pb"), 0.01)
        bFactor = (1 - b) / (nominalPotential - vto)
        let nominalBeta = Self.beta(idss: max(p("idss"), 1e-12), vto: vto, b: b, bFactor: bFactor)
        lambda = max(p("lambda"), 0)
        rd = max(p("rd"), 0)
        rs = max(p("rs"), 0)
        kf = max(p("kf"), 0)
        af = p("af")

        // at temperature (jfettemp.c)
        let ratio = kelvin / tnom
        saturation = max(p("saturationCurrent"), 1e-30) * exp((ratio - 1) * p("eg") / vt) * pow(ratio, p("xti"))
        threshold = vto - p("tcv") * (kelvin - tnom)
        beta = p("betatce") != 0 ? nominalBeta * pow(1.01, p("betatce") * (kelvin - tnom))
                                 : nominalBeta * pow(ratio, p("bex"))
        func pbfact(_ t: Double, _ thermal: Double) -> Double {
            let egfet = 1.16 - (7.02e-4 * t * t) / (t + 1108)
            let arg = -egfet / (2 * boltzmann * t) + 1.1150877 / (boltzmann * (reference + reference))
            return -2 * thermal * (1.5 * log(t / reference) + charge * arg)
        }
        let fact1 = tnom / reference, fact2 = kelvin / reference
        let pbo = (nominalPotential - pbfact(tnom, Simulator.thermalVoltage)) / fact1
        let gmaold = (nominalPotential - pbo) / pbo
        let cjfact = 1 / (1 + 0.5 * (4e-4 * (tnom - reference) - gmaold))
        pb = fact2 * pbo + pbfact(kelvin, vt)
        let gmanew = (pb - pbo) / pbo
        let cjfact1 = 1 + 0.5 * (4e-4 * (kelvin - reference) - gmanew)
        cgs = max(p("cgs"), 0) * cjfact * cjfact1
        cgd = max(p("cgd"), 0) * cjfact * cjfact1
        let fc = min(max(p("fc"), 0), 0.95)
        let xfc = log(1 - fc)
        f2 = exp(1.5 * xfc)
        f3 = 1 - fc * 1.5
        fcv = fc * pb
        f1 = pb * (1 - exp(0.5 * xfc)) / 0.5
        critical = vt * log(vt / (sqrt(2) * saturation))
    }

    /// The pinch-off voltage as SPICE's VTO: negative for a depletion JFET of either polarity
    static func pinchOff(_ element: Element) -> Double {
        min(element[param: "pinchOff"], -0.01)
    }

    /// SPICE's BETA for a JFET drawing `idss` with its gate at its source in saturation
    static func beta(idss: Double, vto: Double, b: Double, bFactor: Double) -> Double {
        idss / (vto * vto * (b - bFactor * vto))
    }

    /// The gate junctions' and the channel's currents at `vgs` and `vgd` (gate to internal source and drain, in the
    /// transistor's polarity), with SPICE's gmin across each junction
    func currents(vgs: Double, vgd: Double, gmin: Double) -> Currents {
        var r = Currents()
        func junction(_ v: Double) -> (Double, Double) {
            if v < -3 * vt {
                var arg = 3 * vt / (v * M_E)
                arg = arg * arg * arg
                return (-saturation * (1 + arg) + gmin * v, saturation * 3 * arg / v + gmin)
            }
            let e = exp(min(v / vt, 700))
            return (saturation * (e - 1) + gmin * v, saturation * e / vt + gmin)
        }
        let (cgs, ggs) = junction(vgs)
        (r.cgd, r.ggd) = junction(vgd)
        r.cg = cgs + r.cgd
        r.ggs = ggs
        let vds = vgs - vgd
        if vds >= 0 {
            let vgst = vgs - threshold
            if vgst > 0 {
                let betap = beta * (1 + lambda * vds)
                if vgst >= vds {
                    // linear region
                    let apart = 2 * b + 3 * bFactor * (vgst - vds)
                    let cpart = vds * (vds * (bFactor * vds - b) + vgst * apart)
                    r.cdrain = betap * cpart
                    r.gm = betap * vds * (apart + 3 * bFactor * vgst)
                    r.gds = betap * (vgst - vds) * apart + beta * lambda * cpart
                } else {
                    // saturation
                    let bf = vgst * bFactor
                    r.gm = betap * vgst * (2 * b + 3 * bf)
                    let cpart = vgst * vgst * (b + bf)
                    r.cdrain = betap * cpart
                    r.gds = lambda * beta * cpart
                }
            }
        } else {
            // inverse mode: the drain acts as the source
            let vgdt = vgd - threshold
            if vgdt > 0 {
                let betap = beta * (1 - lambda * vds)
                if vgdt + vds >= 0 {
                    let apart = 2 * b + 3 * bFactor * (vgdt + vds)
                    let cpart = vds * (-vds * (-bFactor * vds - b) + vgdt * apart)
                    r.cdrain = betap * cpart
                    r.gm = betap * vds * (apart + 3 * bFactor * vgdt)
                    r.gds = betap * (vgdt + vds) * apart - beta * lambda * cpart - r.gm
                } else {
                    let bf = vgdt * bFactor
                    r.gm = -betap * vgdt * (2 * b + 3 * bf)
                    let cpart = vgdt * vgdt * (b + bf)
                    r.cdrain = -betap * cpart
                    r.gds = lambda * beta * cpart - r.gm
                }
            }
        }
        return r
    }

    /// The gate-source and gate-drain depletion charges at `vgs` and `vgd`, and their capacitances (grading 1/2)
    func charges(vgs: Double, vgd: Double) -> Charges {
        func depletion(_ v: Double, _ cz: Double) -> (Double, Double) {
            guard cz > 0 else { return (0, 0) }
            let twop = pb + pb
            if v < fcv {
                let sarg = (1 - v / pb).squareRoot()
                return (twop * cz * (1 - sarg), cz / sarg)
            }
            let czf2 = cz / f2
            return (cz * f1 + czf2 * (f3 * (v - fcv) + (v * v - fcv * fcv) / (twop + twop)), czf2 * (f3 + v / twop))
        }
        var q = Charges()
        (q.qgs, q.capgs) = depletion(vgs, cgs)
        (q.qgd, q.capgd) = depletion(vgd, cgd)
        return q
    }

    /// The SPICE names of the card's parameters and the keys JSpice keeps them under (BETA is worked out from IDSS)
    static let card: [(spice: String, key: String)] = [
        ("VTO", "pinchOff"), ("LAMBDA", "lambda"), ("B", "b"), ("RD", "rd"), ("RS", "rs"), ("IS", "saturationCurrent"),
        ("CGS", "cgs"), ("CGD", "cgd"), ("PB", "pb"), ("FC", "fc"), ("TCV", "tcv"), ("BEX", "bex"),
        ("BETATCE", "betatce"), ("XTI", "xti"), ("EG", "eg"), ("KF", "kf"), ("AF", "af"),
    ]
    static let aliases = ["VT0": "VTO"]
    /// Parameters a card can have that JSpice leaves out, with the value that makes no difference
    static let ignored: [String: Double] = ["TNOM": 27, "AREA": 1, "M": 0.5, "N": 1, "ISR": 0, "NR": 2, "ALPHA": 0, "VK": 0,
                                            "NLEV": 2, "GDSNOI": 1, "LEVEL": 1]
    /// SPICE's values for the parameters whose defaults in JSpice are not SPICE's
    static let spiceDefaults: [String: Double] = ["pinchOff": -2, "lambda": 0, "cgs": 0, "cgd": 0]

    /// A `.model` card's parameters (by their SPICE names, upper case) as JSpice's, and what it leaves out
    static func parameters(fromCard card: [String: Double]) -> (params: [String: Double], ignored: [String]) {
        var spice: [String: Double] = [:]
        for (name, value) in card { spice[aliases[name] ?? name] = value }
        // VTOTC is TCV with the other sign
        if let vtotc = spice["VTOTC"] {
            spice["TCV"] = -vtotc
            spice["VTOTC"] = nil
        }
        // BETATCE wins over BEX, as in ngspice
        if spice["BETATCE"] != nil { spice["BEX"] = nil }
        var params = spiceDefaults
        for (name, key) in Self.card {
            guard let value = spice[name] else { continue }
            params[key] = value
        }
        let vto = min(params["pinchOff"] ?? -2, -0.01)
        params["pinchOff"] = vto
        let b = (params["b"] ?? 1) > 0 ? params["b"] ?? 1 : 1
        let pb = max(params["pb"] ?? 1, 0.01)
        let bFactor = (1 - b) / (pb - vto)
        params["idss"] = (spice["BETA"] ?? 1e-4) * vto * vto * (b - bFactor * vto)
        let known = Set(Self.card.map(\.spice) + ["BETA"])
        let left = spice.filter { !known.contains($0.key) && Self.ignored[$0.key] != $0.value }.map(\.key).sorted()
        return (params, left)
    }

    /// A JFET's parameters (`value` reads them) as the body of a `.model` card: VTO and BETA, and the rest not at
    /// SPICE's defaults
    static func cardText(_ value: (String) -> Double, kind: ElementKind) -> String {
        let vto = min(value("pinchOff"), -0.01)
        let b = value("b") > 0 ? value("b") : 1
        let bFactor = (1 - b) / (max(value("pb"), 0.01) - vto)
        let beta = Self.beta(idss: max(value("idss"), 1e-12), vto: vto, b: b, bFactor: bFactor)
        var words = ["BETA=\(String(format: "%.6g", beta))"]
        for (name, key) in Self.card {
            let v = name == "VTO" ? vto : value(key)
            let standard = spiceDefaults[key] ?? kind.params.first { $0.key == key }?.defaultValue ?? 0
            if name == "VTO" || v != standard { words.append("\(name)=\(String(format: "%.6g", v))") }
        }
        return words.joined(separator: " ")
    }
}
