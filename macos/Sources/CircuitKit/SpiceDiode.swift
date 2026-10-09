import Foundation

/// A diode as SPICE models it (ngspice's level 1, from `diotemp.c` and `dioload.c`), with the parameters of a `.model`
/// card: the junction's current with its emission coefficient, reverse breakdown matched to IBV at BV with its own
/// emission coefficient, high-injection knees, a series resistance on an internal node, the depletion and diffusion
/// charges, and the temperature. Diodes, Zener diodes and LEDs are all this; a Zener's card has BV, an LED's its colour's
/// saturation current. Not modelled: the sidewall, tunnelling and recombination currents, self-heating, and the
/// temperature coefficients of BV, RS, TT and M (TCV, TRS1…).
struct SpiceDiode {
    var saturation = 1e-14, emission = 1.0
    var rs = 0.0
    /// Breakdown voltage at temperature, matched to IBV (0: no breakdown), and its emission coefficient
    var breakdown = 0.0, breakdownEmission = 1.0
    var kneeForward = 0.0, kneeReverse = 0.0
    var tt = 0.0
    var cj0 = 0.0, vj = 1.0, m = 0.5, fcv = 0.5, f1 = 0.0, f2 = 1.0, f3 = 1.0
    var kf = 0.0, af = 1.0
    var vt = Simulator.thermalVoltage
    /// The forward voltage above which SPICE limits Newton-Raphson's steps
    var critical = 0.0

    var hasSeriesNode: Bool { rs > 0 }
    var hasCharges: Bool { cj0 > 0 || tt > 0 }
    var vte: Double { emission * vt }

    /// The internal node a diode with these parameters has
    static func internalNodes(_ element: Element) -> Int { element[param: "rs"] > 0 ? 1 : 0 }

    init() {}

    /// The card of `element` (a diode, Zener diode or LED) at `kelvin`, where the thermal voltage is `vt`
    init(_ element: Element, kelvin: Double, vt: Double) {
        func p(_ key: String) -> Double {
            let value = element[param: key]
            return value.isFinite ? value : 0
        }
        self.vt = vt
        emission = max(p("emission"), 0.01)
        var nominalSaturation = max(p("saturationCurrent"), 1e-30)
        if element.kind == .led && p("saturationCurrent") <= 0 {
            // from the colour: the forward voltage at 10 mA (fitted at the nominal temperature)
            let color = LEDColor(rawValue: Int(Simulator.choice(p("color"), 0...4))) ?? .red
            nominalSaturation = 0.01 / exp(color.forwardVoltage / (emission * Simulator.thermalVoltage))
        }
        let tnom = Simulator.nominalKelvin
        let ratio = kelvin / tnom
        saturation = nominalSaturation * exp((ratio - 1) * p("eg") / (emission * vt) + p("xti") / emission * log(ratio))
        rs = max(p("rs"), 0)
        kneeForward = max(p("ikf"), 0)
        kneeReverse = max(p("ikr"), 0)
        tt = max(p("tt"), 0)
        kf = max(p("kf"), 0)
        af = p("af")

        // depletion capacitance and potential at temperature, as for a transistor's junctions
        let boltzmann = 1.38064852e-23, charge = 1.6021766208e-19, reference = 300.15
        func pbfact(_ t: Double, _ thermal: Double) -> Double {
            let egfet = 1.16 - (7.02e-4 * t * t) / (t + 1108)
            let arg = -egfet / (2 * boltzmann * t) + 1.1150877 / (boltzmann * (reference + reference))
            return -2 * thermal * (1.5 * log(t / reference) + charge * arg)
        }
        m = min(max(p("m"), 0), 0.9)
        let fc = min(max(p("fc"), 0), 0.9999)
        cj0 = max(p("cj0"), 0)
        vj = max(p("vj"), 0.01)
        if kelvin != tnom {
            let fact1 = tnom / reference, fact2 = kelvin / reference
            let pbo = (vj - pbfact(tnom, Simulator.thermalVoltage)) / fact1
            let gmaold = (vj - pbo) / pbo
            cj0 /= 1 + m * (400e-6 * (tnom - reference) - gmaold)
            vj = pbfact(kelvin, vt) + fact2 * pbo
            let gmanew = (vj - pbo) / pbo
            cj0 *= 1 + m * (400e-6 * (kelvin - reference) - gmanew)
        }
        // (the potential limited so that FC times it is at most 1 V)
        if fc * vj > 1 { vj = 1 / fc }
        let xfc = log(1 - fc)
        fcv = fc * vj
        f1 = vj * (1 - exp((1 - m) * xfc)) / (1 - m)
        f2 = exp((1 + m) * xfc)
        f3 = 1 - fc * (1 + m)
        critical = vte * log(vte / (sqrt(2) * saturation))

        // breakdown: the voltage where the reverse current, ideal part included, is IBV
        breakdownEmission = p("nbv") > 0 ? p("nbv") : emission
        let bv = abs(p(element.kind == .zener ? "breakdown" : "bv"))
        if bv > 0 {
            let current = max(p("ibv"), 1e-30)
            let nbvt = breakdownEmission * vt
            var xbv = bv
            if current >= saturation * bv / vt {
                xbv = bv - nbvt * log(1 + current / saturation)
                for _ in 0..<25 {
                    xbv = bv - nbvt * log(current / saturation + 1 - xbv / vt)
                    let matched = saturation * (exp((bv - xbv) / nbvt) - 1 + xbv / vt)
                    if abs(matched - current) <= 1e-9 * current { break }
                }
            }
            breakdown = xbv
        }
    }

    /// The junction's current at `vd` (anode to cathode, inside the series resistance) and its slope, with SPICE's gmin
    /// across it
    func current(_ vd: Double, gmin: Double) -> (current: Double, conductance: Double) {
        let vte = self.vte
        var cd: Double, gd: Double
        if vd >= -3 * vte {
            let e = exp(min(vd / vte, 700))
            cd = saturation * (e - 1)
            gd = saturation * e / vte
        } else if breakdown == 0 || vd >= -breakdown {
            var arg = 3 * vte / (vd * M_E)
            arg = arg * arg * arg
            cd = -saturation * (1 + arg)
            gd = saturation * 3 * arg / vd
        } else {
            let nbvt = breakdownEmission * vt
            let e = exp(min(-(breakdown + vd) / nbvt, 700))
            cd = -saturation * e
            gd = saturation * e / nbvt
        }
        // high injection, forward and reverse
        if vd >= -3 * vte {
            if kneeForward > 0 && cd > 1e-18 {
                let root = (cd / kneeForward).squareRoot()
                gd = ((1 + root) * gd - cd * gd / (2 * root * kneeForward)) / (1 + 2 * root + cd / kneeForward)
                cd /= 1 + root
            }
        } else if kneeReverse > 0 && cd < -1e-18 {
            let root = (cd / -kneeReverse).squareRoot()
            gd = ((1 + root) * gd + cd * gd / (2 * root * kneeReverse)) / (1 + 2 * root - cd / kneeReverse)
            cd /= 1 + root
        }
        return (cd + gmin * vd, gd + gmin)
    }

    /// The charge at `vd` and its slope: the depletion charge and the diffusion charge TT times the current
    func charge(_ vd: Double, current: (current: Double, conductance: Double)) -> (charge: Double, capacitance: Double) {
        var q = tt * current.current, cap = tt * current.conductance
        if cj0 > 0 {
            if vd < fcv {
                let arg = 1 - vd / vj
                let sarg = exp(-m * log(arg))
                q += vj * cj0 * (1 - arg * sarg) / (1 - m)
                cap += cj0 * sarg
            } else {
                let cjf2 = cj0 / f2
                q += cj0 * f1 + cjf2 * (f3 * (vd - fcv) + m / (vj + vj) * (vd * vd - fcv * fcv))
                cap += cjf2 * (f3 + m * vd / vj)
            }
        }
        return (q, cap)
    }

    /// Newton-Raphson's step at the junction limited as SPICE limits it: in breakdown about the breakdown voltage
    func limit(_ new: Double, old: Double, _ limitJunction: (Double, Double, Double, Double) -> Double) -> Double {
        let nbvt = breakdownEmission * vt
        if breakdown > 0 && new < min(0, -breakdown + 10 * nbvt) {
            let reverse = limitJunction(-(new + breakdown), -(old + breakdown), nbvt, critical)
            return -(reverse + breakdown)
        }
        return limitJunction(new, old, vte, critical)
    }

    /// The SPICE names of the card's parameters and the keys JSpice keeps them under (a Zener's BV is its breakdown)
    static func card(_ kind: ElementKind) -> [(spice: String, key: String)] {
        [("IS", "saturationCurrent"), ("N", "emission"), ("RS", "rs"), ("CJO", "cj0"), ("VJ", "vj"), ("M", "m"),
         ("FC", "fc"), ("TT", "tt"), ("BV", kind == .zener ? "breakdown" : "bv"), ("IBV", "ibv"), ("NBV", "nbv"),
         ("IKF", "ikf"), ("IKR", "ikr"), ("EG", "eg"), ("XTI", "xti"), ("KF", "kf"), ("AF", "af")]
    }
    static let aliases = ["CJ0": "CJO", "CJ": "CJO", "PB": "VJ", "MJ": "M"]
    /// Parameters a card can have that JSpice leaves out, with the value that makes no difference
    static let ignored: [String: Double] = ["TNOM": 27, "TCV": 0, "TRS1": 0, "TRS2": 0, "TTT1": 0, "TTT2": 0, "TM1": 0,
                                            "TM2": 0, "ISW": 0, "JSW": 0, "CJSW": 0, "CJP": 0, "AREA": 1, "LEVEL": 1]

    /// A `.model` card's parameters as JSpice's for `kind`, and what it leaves out: SPICE's defaults where JSpice's
    /// differ (a drawn diode has a small capacitance)
    static func parameters(fromCard card: [String: Double], kind: ElementKind) -> (params: [String: Double], ignored: [String]) {
        var spice: [String: Double] = [:]
        for (name, value) in card { spice[aliases[name] ?? name] = value }
        var params: [String: Double] = ["saturationCurrent": 1e-14, "emission": 1, "cj0": 0, "ibv": 1e-3]
        for (name, key) in Self.card(kind) {
            guard let value = spice[name] else { continue }
            params[key] = name == "BV" ? abs(value) : value
        }
        let known = Set(Self.card(kind).map(\.spice))
        let left = spice.filter { !known.contains($0.key) && Self.ignored[$0.key] != $0.value }.map(\.key).sorted()
        return (params, left)
    }

    /// A diode's parameters (`value` reads them) as the body of a `.model` card
    static func cardText(_ value: (String) -> Double, kind: ElementKind) -> String {
        var words: [String] = []
        let specs = kind.params
        for (name, key) in Self.card(kind) {
            var v = value(key)
            if name == "IS" && kind == .led && v <= 0 {
                let color = LEDColor(rawValue: Int(Simulator.choice(value("color"), 0...4))) ?? .red
                v = 0.01 / exp(color.forwardVoltage / (max(value("emission"), 0.01) * Simulator.thermalVoltage))
            }
            let standard: Double = ["saturationCurrent": 1e-14, "emission": 1, "cj0": 0, "ibv": 1e-3][key]
                ?? specs.first { $0.key == key }?.defaultValue ?? 0
            // a breakdown voltage is written whenever there is one (SPICE's default is none; 0 is none here)
            if name == "BV" {
                if v > 0 { words.append("BV=\(String(format: "%.6g", v))") }
                continue
            }
            if name == "IS" || name == "N" || v != standard { words.append("\(name)=\(String(format: "%.6g", v))") }
        }
        return words.joined(separator: " ")
    }
}
