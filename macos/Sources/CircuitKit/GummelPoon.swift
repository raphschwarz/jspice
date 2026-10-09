import Foundation

/// A bipolar transistor as SPICE models it: the Gummel-Poon model of SPICE2 and SPICE3, ngspice's level 1, with the
/// parameters of a `.model` card. Its equations are ngspice's (`bjttemp.c` and `bjtload.c`), so a manufacturer's card
/// behaves as it does in ngspice; `crosscheck.py` checks that it does.
///
/// With only IS, BF, CJE, CJC and TF given it is the Ebers-Moll transistor JSpice had before (BR 1, no Early effect,
/// no high-level injection, no leakage, no resistances). Not modelled: excess phase (PTF), the substrate junction
/// (CJS, ISS), the temperature coefficients of the resistances and of IKF and VAF (TRB1, TIKF1…), quasi-saturation.
struct GummelPoon {
    /// Parameters as worked out at the circuit's temperature
    var saturation = 1e-14
    var betaF = 100.0, betaR = 1.0
    var nf = 1.0, nr = 1.0
    var leakBE = 0.0, ne = 1.5
    var leakBC = 0.0, nc = 2.0
    var invEarlyF = 0.0, invEarlyR = 0.0
    var invKneeF = 0.0, invKneeR = 0.0
    var nkf = 0.5
    var rb = 0.0, rbm = 0.0, irb = 0.0
    var rc = 0.0, re = 0.0
    var tf = 0.0, xtf = 0.0, vtfFactor = 0.0, itf = 0.0, tr = 0.0
    // depletion capacitances: zero-bias capacitance, junction potential, grading, and the constants of their straight
    // continuation above FC times the potential (base-emitter, and base-collector split by XCJC into the part at the
    // internal base and the part at the external base)
    var cje = 0.0, vje = 0.75, mje = 0.33, fcBE = 0.375, f1BE = 0.0, f2BE = 1.0, f3BE = 1.0
    var cjcInner = 0.0, cjcOuter = 0.0, vjc = 0.75, mjc = 0.33, fcBC = 0.375, f1BC = 0.0, f2BC = 1.0, f3BC = 1.0
    var kf = 0.0, af = 1.0
    /// Thermal voltage, and the junction voltage above which SPICE limits Newton-Raphson's steps
    var vt = Simulator.thermalVoltage
    var critical = 0.0

    /// Whether the base, collector and emitter have internal nodes (their resistances are not zero), in that order
    /// after the three terminals
    var hasBaseNode: Bool { rb > 0 }
    var hasCollectorNode: Bool { rc > 0 }
    var hasEmitterNode: Bool { re > 0 }
    /// The base resistance falls with the base current (RBM differs from RB): stamped at every iteration
    var baseModulated: Bool { rb > 0 && rbm != rb }
    var hasCharges: Bool { cje > 0 || cjcInner > 0 || cjcOuter > 0 || tf > 0 || tr > 0 }

    /// The internal nodes a transistor with these parameters has
    static func internalNodes(_ element: Element) -> Int {
        (element[param: "rb"] > 0 ? 1 : 0) + (element[param: "rc"] > 0 ? 1 : 0) + (element[param: "re"] > 0 ? 1 : 0)
    }

    init() {}

    /// The card of `element` at `kelvin`, where the thermal voltage is `vt`
    init(_ element: Element, kelvin: Double, vt: Double) {
        func p(_ key: String) -> Double {
            let value = element[param: key]
            return value.isFinite ? value : 0
        }
        self.vt = vt
        let tnom = Simulator.nominalKelvin
        // ngspice's constants (const.h), for the junction potentials' temperature
        let boltzmann = 1.38064852e-23, charge = 1.6021766208e-19, reference = 300.15
        let ratio = kelvin / tnom
        let ratlog = log(ratio)
        let factlog = (ratio - 1) * p("eg") / vt + p("xti") * ratlog
        let factor = exp(factlog)
        let bfactor = exp(ratlog * p("xtb"))
        saturation = max(p("saturationCurrent"), 1e-30) * factor
        betaF = max(p("beta"), 1e-6) * bfactor
        betaR = max(p("br"), 1e-6) * bfactor
        nf = max(p("nf"), 0.01)
        nr = max(p("nr"), 0.01)
        ne = max(p("ne"), 0.01)
        nc = max(p("nc"), 0.01)
        leakBE = max(p("ise"), 0) * exp(factlog / ne) / bfactor
        leakBC = max(p("isc"), 0) * exp(factlog / nc) / bfactor
        invEarlyF = p("vaf") != 0 ? 1 / p("vaf") : 0
        invEarlyR = p("var") != 0 ? 1 / p("var") : 0
        invKneeF = p("ikf") != 0 ? 1 / p("ikf") : 0
        invKneeR = p("ikr") != 0 ? 1 / p("ikr") : 0
        nkf = p("nkf") > 0 ? p("nkf") : 0.5
        rb = max(p("rb"), 0)
        // RBM is RB unless given (an explicit RBM of 0 comes in as a tiny resistance)
        rbm = p("rbm") > 0 ? p("rbm") : rb
        irb = max(p("irb"), 0)
        rc = max(p("rc"), 0)
        re = max(p("re"), 0)
        tf = max(p("tf"), 0)
        xtf = max(p("xtf"), 0)
        vtfFactor = p("vtf") != 0 ? 1 / (1.44 * p("vtf")) : 0
        itf = max(p("itf"), 0)
        tr = max(p("tr"), 0)
        kf = max(p("kf"), 0)
        af = p("af")

        // depletion capacitances and potentials at temperature (ngspice-42's bjttemp.c: the potential at absolute zero
        // from the nominal temperature's band gap, then out to the circuit's)
        let fact1 = tnom / reference, fact2 = kelvin / reference
        func pbfact(_ t: Double, _ thermal: Double) -> Double {
            let egfet = 1.16 - (7.02e-4 * t * t) / (t + 1108)
            let arg = -egfet / (2 * boltzmann * t) + 1.1150877 / (boltzmann * (reference + reference))
            return -2 * thermal * (1.5 * log(t / reference) + charge * arg)
        }
        let pbfactT = pbfact(kelvin, vt), pbfactNominal = pbfact(tnom, Simulator.thermalVoltage)
        func atTemperature(_ cj: Double, _ vj: Double, _ m: Double) -> (cj: Double, vj: Double) {
            guard kelvin != tnom else { return (cj, vj) }
            let pbo = (vj - pbfactNominal) / fact1
            let gmaold = (vj - pbo) / pbo
            var cap = cj / (1 + m * (4e-4 * (tnom - reference) - gmaold))
            let pot = fact2 * pbo + pbfactT
            let gmanew = (pot - pbo) / pbo
            cap *= 1 + m * (4e-4 * (kelvin - reference) - gmanew)
            return (cap, pot)
        }
        let fc = min(max(p("fc"), 0), 0.9999)
        let xfc = log(1 - fc)
        mje = min(max(p("mje"), 0), 0.999)
        mjc = min(max(p("mjc"), 0), 0.999)
        (cje, vje) = atTemperature(max(p("cje"), 0), max(p("vje"), 0.01), mje)
        let collector = atTemperature(max(p("cjc"), 0), max(p("vjc"), 0.01), mjc)
        vjc = collector.vj
        let xcjc = min(max(p("xcjc"), 0), 1)
        cjcInner = collector.cj * xcjc
        cjcOuter = collector.cj - cjcInner
        fcBE = fc * vje
        f1BE = vje * (1 - exp((1 - mje) * xfc)) / (1 - mje)
        f2BE = exp((1 + mje) * xfc)
        f3BE = 1 - fc * (1 + mje)
        fcBC = fc * vjc
        f1BC = vjc * (1 - exp((1 - mjc) * xfc)) / (1 - mjc)
        f2BC = exp((1 + mjc) * xfc)
        f3BC = 1 - fc * (1 + mjc)
        critical = vt * log(vt / (sqrt(2) * saturation))
    }

    /// The currents at junction voltages `vbe` and `vbc` (internal, in the transistor's own polarity) and their slopes
    struct Currents {
        /// Collector current (into the internal collector) and base current (into the internal base)
        var cc = 0.0, cb = 0.0
        /// ∂cb/∂vbe, ∂cb/∂vbc; the transconductance and output conductance: ∂cc/∂vbe = gm + go, ∂cc/∂vbc = −go − gmu
        var gpi = 0.0, gmu = 0.0, gm = 0.0, go = 0.0
        /// The base resistance's conductance (0 without one)
        var gx = 0.0
        /// The forward and reverse diffusion currents IS·(e^(v/NV) − 1) and their slopes, the normalised base charge and
        /// its slopes: what the stored charges are made of
        var cbe = 0.0, gbe = 0.0, cbc = 0.0, gbc = 0.0, qb = 1.0, dqbdve = 0.0, dqbdvc = 0.0
    }

    /// A junction's ideal current and slope, continued below −3 NV by SPICE's cubic so that it saturates smoothly
    @inline(__always) private static func junction(_ v: Double, _ saturation: Double, _ nvt: Double) -> (Double, Double) {
        if v >= -3 * nvt {
            let e = exp(min(v / nvt, 700))
            return (saturation * (e - 1), saturation * e / nvt)
        }
        var arg = 3 * nvt / (v * M_E)
        arg = arg * arg * arg
        return (-saturation * (1 + arg), saturation * 3 * arg / v)
    }

    func currents(vbe: Double, vbc: Double, gmin: Double) -> Currents {
        var r = Currents()
        (r.cbe, r.gbe) = Self.junction(vbe, saturation, nf * vt)
        var (cben, gben) = leakBE != 0 ? Self.junction(vbe, leakBE, ne * vt) : (0, 0)
        gben += gmin
        cben += gmin * vbe
        (r.cbc, r.gbc) = Self.junction(vbc, saturation, nr * vt)
        var (cbcn, gbcn) = leakBC != 0 ? Self.junction(vbc, leakBC, nc * vt) : (0, 0)
        gbcn += gmin
        cbcn += gmin * vbc
        // the base charge: the Early effect, and high-level injection at the knee currents
        let q1 = 1 / (1 - invEarlyF * vbc - invEarlyR * vbe)
        if invKneeF == 0 && invKneeR == 0 {
            r.qb = q1
            r.dqbdve = q1 * r.qb * invEarlyR
            r.dqbdvc = q1 * r.qb * invEarlyF
        } else {
            let q2 = invKneeF * r.cbe + invKneeR * r.cbc
            let arg = max(0, 1 + 4 * q2)
            let square = nkf == 0.5
            let sqarg = arg != 0 ? (square ? arg.squareRoot() : pow(arg, nkf)) : 1
            r.qb = q1 * (1 + sqarg) / 2
            if square || arg == 0 {
                r.dqbdve = q1 * (r.qb * invEarlyR + invKneeF * r.gbe / sqarg)
                r.dqbdvc = q1 * (r.qb * invEarlyF + invKneeR * r.gbc / sqarg)
            } else {
                r.dqbdve = q1 * (r.qb * invEarlyR + invKneeF * r.gbe * 2 * sqarg * nkf / arg)
                r.dqbdvc = q1 * (r.qb * invEarlyF + invKneeR * r.gbc * 2 * sqarg * nkf / arg)
            }
        }
        r.cc = (r.cbe - r.cbc) / r.qb - r.cbc / betaR - cbcn
        r.cb = r.cbe / betaF + cben + r.cbc / betaR + cbcn
        if rb > 0 {
            var resistance = rbm + (rb - rbm) / r.qb
            if irb != 0 {
                let arg1 = max(r.cb / irb, 1e-9)
                let arg2 = (-1 + (1 + 14.59025 * arg1).squareRoot()) / 2.4317 / arg1.squareRoot()
                let t = tan(arg2)
                resistance = rbm + 3 * (rb - rbm) * (t - arg2) / arg2 / t / t
            }
            r.gx = resistance != 0 ? 1 / resistance : 0
        }
        r.gpi = r.gbe / betaF + gben
        r.gmu = r.gbc / betaR + gbcn
        r.go = (r.gbc + (r.cbe - r.cbc) * r.dqbdvc / r.qb) / r.qb
        r.gm = (r.gbe - (r.cbe - r.cbc) * r.dqbdve / r.qb) / r.qb - r.go
        return r
    }

    /// The stored charges: base-emitter (depletion, and the forward current's over TF, rising with XTF towards ITF and
    /// with the collector voltage by VTF), base-collector at the internal base (depletion and the reverse current's over
    /// TR), and base-collector at the external base (depletion), with their capacitances; and how the base-emitter
    /// charge moves with vbc (a transcapacitance)
    struct Charges {
        var qbe = 0.0, capbe = 0.0, dqbeVbc = 0.0
        var qbc = 0.0, capbc = 0.0
        var qbx = 0.0, capbx = 0.0
    }

    /// A depletion charge and its capacitance (SPICE's, continued in a straight line above FC times the potential)
    @inline(__always) private static func depletion(_ v: Double, cj: Double, vj: Double, m: Double, fcv: Double, f1: Double,
                                                    f2: Double, f3: Double) -> (Double, Double) {
        guard cj > 0 else { return (0, 0) }
        if v < fcv {
            let arg = 1 - v / vj
            let sarg = exp(-m * log(arg))
            return (vj * cj * (1 - arg * sarg) / (1 - m), cj * sarg)
        }
        let cjf2 = cj / f2
        return (cj * f1 + cjf2 * (f3 * (v - fcv) + m / (vj + vj) * (v * v - fcv * fcv)), cjf2 * (f3 + m * v / vj))
    }

    func charges(vbe: Double, vbc: Double, vbx: Double, _ r: Currents) -> Charges {
        var q = Charges()
        var cbe = r.cbe, gbe = r.gbe
        if tf != 0 && vbe > 0 {
            var argtf = 0.0, arg2 = 0.0, arg3 = 0.0
            if xtf != 0 {
                argtf = xtf
                if vtfFactor != 0 { argtf *= exp(vbc * vtfFactor) }
                arg2 = argtf
                if itf != 0 {
                    let temp = cbe / (cbe + itf)
                    argtf *= temp * temp
                    arg2 = argtf * (3 - temp - temp)
                }
                arg3 = cbe * argtf * vtfFactor
            }
            cbe = cbe * (1 + argtf) / r.qb
            gbe = (gbe * (1 + arg2) - cbe * r.dqbdve) / r.qb
            q.dqbeVbc = tf * (arg3 - cbe * r.dqbdvc) / r.qb
        }
        let (qe, ce) = Self.depletion(vbe, cj: cje, vj: vje, m: mje, fcv: fcBE, f1: f1BE, f2: f2BE, f3: f3BE)
        q.qbe = tf * cbe + qe
        q.capbe = tf * gbe + ce
        let (qc, cc) = Self.depletion(vbc, cj: cjcInner, vj: vjc, m: mjc, fcv: fcBC, f1: f1BC, f2: f2BC, f3: f3BC)
        q.qbc = tr * r.cbc + qc
        q.capbc = tr * r.gbc + cc
        (q.qbx, q.capbx) = Self.depletion(vbx, cj: cjcOuter, vj: vjc, m: mjc, fcv: fcBC, f1: f1BC, f2: f2BC, f3: f3BC)
        return q
    }

    /// The SPICE names of the card's parameters and the keys JSpice keeps them under, in a card's usual order
    static let card: [(spice: String, key: String)] = [
        ("IS", "saturationCurrent"), ("BF", "beta"), ("NF", "nf"), ("VAF", "vaf"), ("IKF", "ikf"), ("ISE", "ise"), ("NE", "ne"),
        ("BR", "br"), ("NR", "nr"), ("VAR", "var"), ("IKR", "ikr"), ("ISC", "isc"), ("NC", "nc"), ("NKF", "nkf"),
        ("RB", "rb"), ("IRB", "irb"), ("RBM", "rbm"), ("RE", "re"), ("RC", "rc"),
        ("CJE", "cje"), ("VJE", "vje"), ("MJE", "mje"), ("TF", "tf"), ("XTF", "xtf"), ("VTF", "vtf"), ("ITF", "itf"),
        ("CJC", "cjc"), ("VJC", "vjc"), ("MJC", "mjc"), ("XCJC", "xcjc"), ("TR", "tr"), ("FC", "fc"),
        ("XTB", "xtb"), ("EG", "eg"), ("XTI", "xti"), ("KF", "kf"), ("AF", "af"),
    ]
    /// Other spellings SPICE accepts
    static let aliases = ["VA": "VAF", "VB": "VAR", "IK": "IKF", "PE": "VJE", "ME": "MJE", "PC": "VJC", "MC": "MJC"]
    /// Parameters a card can have that JSpice leaves out, with the value that makes no difference
    static let ignored: [String: Double] = ["PTF": 0, "CJS": 0, "CCS": 0, "ISS": 0, "TNOM": 27, "VJS": 0.75, "MJS": 0,
                                            "PS": 0.75, "MS": 0, "NS": 1, "TRB1": 0, "TRB2": 0, "TRM1": 0, "TRM2": 0,
                                            "TRE1": 0, "TRE2": 0, "TRC1": 0, "TRC2": 0, "TIKF1": 0, "TIKF2": 0, "TIKR1": 0,
                                            "TIKR2": 0, "TVAF1": 0, "TVAF2": 0, "TVAR1": 0, "TVAR2": 0, "TLEV": 0, "TLEVC": 0]

    /// A `.model` card's parameters (by their SPICE names, upper case) as JSpice's, and what it leaves out
    static func parameters(fromCard card: [String: Double]) -> (params: [String: Double], ignored: [String]) {
        var spice: [String: Double] = [:]
        for (name, value) in card { spice[aliases[name] ?? name] = value }
        // SPICE2's leakage currents as multiples of IS
        let saturation = spice["IS"] ?? 1e-16
        if spice["ISE"] == nil, let c2 = spice["C2"] { spice["ISE"] = c2 * saturation }
        if spice["ISC"] == nil, let c4 = spice["C4"] { spice["ISC"] = c4 * saturation }
        // SPICE's defaults where JSpice's differ (a drawn transistor has small capacitances)
        var params = spiceDefaults
        for (name, key) in Self.card {
            guard var value = spice[name] else { continue }
            if name == "RBM" && value == 0 { value = 1e-12 }
            params[key] = value
        }
        let known = Set(Self.card.map(\.spice) + ["C2", "C4", "LEVEL"])
        let left = spice.filter { !known.contains($0.key) && Self.ignored[$0.key] != $0.value }.map(\.key).sorted()
        return (params, left)
    }

    /// SPICE's values for the parameters whose defaults in JSpice are not SPICE's
    static let spiceDefaults: [String: Double] = ["saturationCurrent": 1e-16, "cje": 0, "cjc": 0]

    /// A transistor's parameters (`value` reads them) as the body of a `.model` card: IS and BF, and those not at
    /// SPICE's defaults
    static func cardText(_ value: (String) -> Double, kind: ElementKind) -> String {
        var words: [String] = []
        for (name, key) in Self.card {
            let v = value(key)
            let standard = spiceDefaults[key] ?? kind.params.first { $0.key == key }?.defaultValue ?? 0
            if name == "IS" || name == "BF" || v != standard { words.append("\(name)=\(String(format: "%.6g", v))") }
        }
        return words.joined(separator: " ")
    }
}
