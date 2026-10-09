import Foundation

/// A MOSFET as SPICE models it: ngspice's level 1 (Shichman-Hodges), with the parameters of a `.model` card. Its
/// equations are ngspice's (`mos1temp.c` and `mos1load.c`): the channel current in both directions with channel-length
/// modulation and the body effect, drain and source resistances on internal nodes, the bulk junctions with their
/// depletion charges, Meyer's gate capacitances with the overlap capacitances, and the temperature. `crosscheck.py`
/// checks it.
///
/// JSpice's MOSFETs have three terminals: the bulk is tied to the source, as a discrete MOSFET's is, which gives it the
/// body diode from source to drain. A drawn MOSFET is set by its threshold and its beta (KP W / L); a card's process
/// parameters (TOX, NSUB, U0, LD, CJ, JS…) are worked out into these with the transistor's W, L and areas when it is read.
/// Not modelled: the sidewall junctions, and flicker noise.
struct SpiceMOSFET {
    /// 1 for N-channel, −1 for P-channel: the voltages in the transistor's own polarity are this times the circuit's
    var type = 1.0
    /// Parameters as worked out at the circuit's temperature: beta (KP W / Leff), the surface potential, the built-in
    /// voltage and the threshold (ngspice's tPhi, tVbi and tVto, the threshold as a card gives it, negative for a PMOS)
    var beta = 0.02, lambda = 0.0, gamma = 0.0
    var phi = 0.6, vbi = 0.0, vto = 1.5
    var rd = 0.0, rs = 0.0
    var saturation = 1e-14
    /// The bulk junctions' zero-bias capacitances and potential, and their straight continuation above FC times it
    var cbd = 0.0, cbs = 0.0, mj = 0.5, pb = 0.8, depCap = 0.4
    var f2d = 0.0, f3d = 0.0, f4d = 0.0, f2s = 0.0, f3s = 0.0, f4s = 0.0
    /// The overlap capacitances and the gate oxide's capacitance (Meyer's model), each the transistor's whole
    var cgso = 0.0, cgdo = 0.0, cgbo = 0.0, cox = 0.0
    var kf = 0.0, af = 1.0
    var vt = Simulator.thermalVoltage
    /// The bulk junction voltage above which SPICE limits Newton-Raphson's steps
    var critical = 0.0

    var hasDrainNode: Bool { rd > 0 }
    var hasSourceNode: Bool { rs > 0 }
    var hasBulkCharges: Bool { cbd > 0 || cbs > 0 }
    var hasGateCharges: Bool { cgso > 0 || cgdo > 0 || cgbo > 0 || cox > 0 }
    var hasCharges: Bool { hasBulkCharges || hasGateCharges }

    /// The internal nodes a MOSFET with these parameters has
    static func internalNodes(_ element: Element) -> Int {
        (element[param: "rd"] > 0 ? 1 : 0) + (element[param: "rs"] > 0 ? 1 : 0)
    }

    /// The transistor at an operating point, in its own polarity: the bulk junctions' currents and the channel's
    struct Currents {
        /// Bulk to source and bulk to drain, with their slopes
        var cbs = 0.0, gbs = 0.0, cbd = 0.0, gbd = 0.0
        /// 1 with the drain above the source, −1 with the source above (the two swapped)
        var mode = 1.0
        /// The channel's current (from the terminal acting as drain to the one acting as source) and its slopes in the
        /// gate, drain and bulk voltages, and where it turns on and saturates
        var cdrain = 0.0, gm = 0.0, gds = 0.0, gmbs = 0.0
        var von = 0.0, vdsat = 0.0
    }

    /// Half of Meyer's gate capacitances at an operating point (SPICE averages each step's two ends)
    struct Meyer {
        var gs = 0.0, gd = 0.0, gb = 0.0
    }

    init() {}

    /// The card of `element` (an NMOS or PMOS) at `kelvin`, where the thermal voltage is `vt`
    init(_ element: Element, kelvin: Double, vt: Double) {
        func p(_ key: String) -> Double {
            let value = element[param: key]
            return value.isFinite ? value : 0
        }
        type = element.kind == .pmos ? -1 : 1
        self.vt = vt
        let tnom = Simulator.nominalKelvin, vtnom = Simulator.thermalVoltage
        let boltzmann = 1.38064852e-23, charge = 1.6021766208e-19, reference = 300.15
        func egfet(_ t: Double) -> Double { 1.16 - (7.02e-4 * t * t) / (t + 1108) }
        func pbfact(_ t: Double, _ thermal: Double) -> Double {
            let arg = -egfet(t) / (2 * boltzmann * t) + 1.1150877 / (boltzmann * (reference + reference))
            return -2 * thermal * (1.5 * log(t / reference) + charge * arg)
        }
        let nominalVto = type * p("threshold")
        let nominalPhi = max(p("phi"), 0.01)
        gamma = max(p("gamma"), 0)
        lambda = max(p("lambda"), 0)
        rd = max(p("rd"), 0)
        rs = max(p("rs"), 0)
        kf = max(p("kf"), 0)
        af = p("af")

        // at temperature (mos1temp.c)
        let ratio = kelvin / tnom
        let fact1 = tnom / reference, fact2 = kelvin / reference
        let pbfact1 = pbfact(tnom, vtnom), pbfactT = pbfact(kelvin, vt)
        let eg1 = egfet(tnom), eg = egfet(kelvin)
        beta = max(p("beta"), 1e-12) / (ratio * ratio.squareRoot())
        let phio = (nominalPhi - pbfact1) / fact1
        phi = fact2 * phio + pbfactT
        vbi = nominalVto - type * gamma * nominalPhi.squareRoot() + 0.5 * (eg1 - eg) + type * 0.5 * (phi - nominalPhi)
        vto = vbi + type * gamma * phi.squareRoot()
        saturation = max(p("saturationCurrent"), 1e-30) * exp(-eg / vt + eg1 / vtnom)

        let nominalPb = max(p("pb"), 0.01)
        mj = min(max(p("mj"), 0), 0.99)
        let pbo = (nominalPb - pbfact1) / fact1
        let gmaold = (nominalPb - pbo) / pbo
        pb = fact2 * pbo + pbfactT
        let gmanew = (pb - pbo) / pbo
        let capfact = (1 + mj * (4e-4 * (kelvin - reference) - gmanew)) / (1 + mj * (4e-4 * (tnom - reference) - gmaold))
        cbd = max(p("cbd"), 0) * capfact
        cbs = max(p("cbs"), 0) * capfact
        let fc = min(max(p("fc"), 0), 0.95)
        depCap = fc * pb
        let arg = 1 - fc
        let sarg = exp(-mj * log(arg))
        f2d = cbd * (1 - fc * (1 + mj)) * sarg / arg
        f3d = cbd * mj * sarg / arg / pb
        f4d = cbd * pb * (1 - arg * sarg) / (1 - mj) - f3d / 2 * depCap * depCap - depCap * f2d
        f2s = cbs * (1 - fc * (1 + mj)) * sarg / arg
        f3s = cbs * mj * sarg / arg / pb
        f4s = cbs * pb * (1 - arg * sarg) / (1 - mj) - f3s / 2 * depCap * depCap - depCap * f2s
        cgso = max(p("cgs"), 0)
        cgdo = max(p("cgd"), 0)
        cgbo = max(p("cgb"), 0)
        cox = max(p("cox"), 0)
        critical = vt * log(vt / (sqrt(2) * saturation))
    }

    /// Where the channel turns on with `vbs` (or `vbd`, in inverse mode) across the bulk junction it is measured from
    func von(bulk vb: Double) -> Double {
        let sarg = vb <= 0 ? (phi - vb).squareRoot() : max(0, phi.squareRoot() - vb / (2 * phi.squareRoot()))
        return type * vbi + gamma * sarg
    }

    /// The bulk junctions' and the channel's currents at `vgs`, `vds` and `vbs` (in the transistor's polarity, from the
    /// gate, internal drain and bulk to the internal source), with SPICE's gmin across each junction
    func currents(vgs: Double, vds: Double, vbs: Double, gmin: Double) -> Currents {
        var r = Currents()
        let vbd = vbs - vds, vgd = vgs - vds
        func junction(_ v: Double) -> (Double, Double) {
            if v <= -3 * vt { return (gmin * v - saturation, gmin) }
            let e = exp(min(709, v / vt))
            return (saturation * (e - 1) + gmin * v, saturation * e / vt + gmin)
        }
        (r.cbs, r.gbs) = junction(vbs)
        (r.cbd, r.gbd) = junction(vbd)
        r.mode = vds >= 0 ? 1 : -1
        let vb = r.mode > 0 ? vbs : vbd
        let sarg = vb <= 0 ? (phi - vb).squareRoot() : max(0, phi.squareRoot() - vb / (2 * phi.squareRoot()))
        r.von = type * vbi + gamma * sarg
        let vgst = (r.mode > 0 ? vgs : vgd) - r.von
        r.vdsat = max(vgst, 0)
        let arg = sarg <= 0 ? 0 : gamma / (sarg + sarg)
        guard vgst > 0 else { return r }
        let v = vds * r.mode
        let betap = beta * (1 + lambda * v)
        if vgst <= v {
            // saturation
            r.cdrain = betap * vgst * vgst * 0.5
            r.gm = betap * vgst
            r.gds = lambda * beta * vgst * vgst * 0.5
        } else {
            // linear region
            r.cdrain = betap * v * (vgst - 0.5 * v)
            r.gm = betap * v
            r.gds = betap * (vgst - v) + lambda * beta * v * (vgst - 0.5 * v)
        }
        r.gmbs = r.gm * arg
        return r
    }

    /// The bulk-drain and bulk-source depletion charges at `vbd` and `vbs`, and their capacitances
    func bulkCharges(vbd: Double, vbs: Double) -> (qbd: Double, capbd: Double, qbs: Double, capbs: Double) {
        func depletion(_ v: Double, _ cz: Double, _ f2: Double, _ f3: Double, _ f4: Double) -> (Double, Double) {
            guard cz > 0 else { return (0, 0) }
            if v < depCap {
                let arg = 1 - v / pb
                let sarg = mj == 0.5 ? 1 / arg.squareRoot() : exp(-mj * log(arg))
                return (pb * cz * (1 - arg * sarg) / (1 - mj), cz * sarg)
            }
            return (f4 + v * (f2 + v * f3 / 2), f2 + v * f3)
        }
        let (qbd, capbd) = depletion(vbd, cbd, f2d, f3d, f4d)
        let (qbs, capbs) = depletion(vbs, cbs, f2s, f3s, f4s)
        return (qbd, capbd, qbs, capbs)
    }

    /// Half of Meyer's gate-source, gate-drain and gate-bulk capacitances (ngspice's DEVqmeyer) at an operating point;
    /// with the drain and source swapped in inverse mode
    func meyer(vgs: Double, vgd: Double, _ r: Currents) -> Meyer {
        guard cox > 0 else { return Meyer() }
        let (vg1, vg2) = r.mode > 0 ? (vgs, vgd) : (vgd, vgs)
        let vgst = vg1 - r.von
        let vdsat = max(r.vdsat, 0.025)
        var m = Meyer()
        var near = 0.0, far = 0.0
        if vgst <= -phi {
            m.gb = cox / 2
        } else if vgst <= -phi / 2 {
            m.gb = -vgst * cox / (2 * phi)
        } else if vgst <= 0 {
            m.gb = -vgst * cox / (2 * phi)
            near = vgst * cox / (1.5 * phi) + cox / 3
            let vds = vg1 - vg2
            if vds < vdsat {
                let vddif = 2 * vdsat - vds, vddif1 = vdsat - vds
                let vddif2 = vddif * vddif
                far = near * (1 - vdsat * vdsat / vddif2)
                near *= 1 - vddif1 * vddif1 / vddif2
            }
        } else {
            let vds = vg1 - vg2
            if vdsat <= vds {
                near = cox / 3
            } else {
                let vddif = 2 * vdsat - vds, vddif1 = vdsat - vds
                let vddif2 = vddif * vddif
                far = cox * (1 - vdsat * vdsat / vddif2) / 3
                near = cox * (1 - vddif1 * vddif1 / vddif2) / 3
            }
        }
        // (DEVqmeyer's values are halves already: cox / 2 accumulated, cox / 3 at the source saturated)
        (m.gs, m.gd) = r.mode > 0 ? (near, far) : (far, near)
        return m
    }

    /// The SPICE names of the card's parameters JSpice keeps as they are, and their keys
    static let card: [(spice: String, key: String)] = [
        ("LAMBDA", "lambda"), ("GAMMA", "gamma"), ("PHI", "phi"), ("RD", "rd"), ("RS", "rs"), ("IS", "saturationCurrent"),
        ("CBD", "cbd"), ("CBS", "cbs"), ("PB", "pb"), ("MJ", "mj"), ("FC", "fc"), ("KF", "kf"), ("AF", "af"),
    ]
    /// Parameters a card can have that JSpice leaves out, with the value that makes no difference
    static let ignored: [String: Double] = ["TNOM": 27, "LEVEL": 1, "CJSW": 0, "MJSW": 0.5, "NSS": 0, "TPG": 1, "NFS": 0]
    /// SPICE's values for the parameters whose defaults in JSpice are not SPICE's
    static let spiceDefaults: [String: Double] = ["lambda": 0]

    /// A `.model` card's parameters (by their SPICE names, upper case) as JSpice's for a transistor of width `w` and
    /// length `l` with drain and source areas and squares (the instance line's W, L, AD, AS, NRD, NRS), and what it
    /// leaves out
    static func parameters(fromCard card: [String: Double], pmos: Bool, w: Double = 1e-4, l: Double = 1e-4,
                           ad: Double = 0, as sourceArea: Double = 0, nrd: Double = 1, nrs: Double = 1)
        -> (params: [String: Double], ignored: [String]) {
        var spice = card
        if let vt0 = spice["VT0"], spice["VTO"] == nil { spice["VTO"] = vt0 }
        let type: Double = pmos ? -1 : 1
        var params = spiceDefaults
        for (name, key) in Self.card {
            guard let value = spice[name] else { continue }
            params[key] = value
        }
        // the process parameters, as ngspice's mos1temp.c works them out at the nominal temperature
        let vtnom = Simulator.thermalVoltage
        let eg1 = 1.16 - (7.02e-4 * Simulator.nominalKelvin * Simulator.nominalKelvin) / (Simulator.nominalKelvin + 1108)
        let effectiveLength = max(l - 2 * (spice["LD"] ?? 0), 1e-12)
        var kp = spice["KP"] ?? 2e-5
        var phi = spice["PHI"] ?? 0.6, gamma = spice["GAMMA"] ?? 0, vto = spice["VTO"] ?? 0
        let oxide = (spice["TOX"] ?? 0) > 0 ? 3.9 * 8.854214871e-12 / spice["TOX"]! : 0
        if oxide > 0 {
            if spice["KP"] == nil { kp = (spice["U0"] ?? spice["UO"] ?? 600) * oxide * 1e-4 }
            if let nsub = spice["NSUB"], nsub * 1e6 > 1.45e16 {
                if spice["PHI"] == nil { phi = max(0.1, 2 * vtnom * log(nsub * 1e6 / 1.45e16)) }
                let fermis = type * 0.5 * phi
                let tpg = spice["TPG"] ?? 1
                var wkfng = 3.2
                if tpg != 0 { wkfng = 3.25 + 0.5 * eg1 - type * tpg * 0.5 * eg1 }
                let wkfngs = wkfng - (3.25 + 0.5 * eg1 + fermis)
                if spice["GAMMA"] == nil { gamma = (2 * 11.70 * 8.854214871e-12 * 1.6021766208e-19 * nsub * 1e6).squareRoot() / oxide }
                if spice["VTO"] == nil {
                    let vfb = wkfngs - (spice["NSS"] ?? 0) * 1e4 * 1.6021766208e-19 / oxide
                    vto = vfb + type * (gamma * phi.squareRoot() + phi)
                }
            }
        }
        params["phi"] = phi
        params["gamma"] = gamma
        params["threshold"] = type * vto
        params["beta"] = kp * w / effectiveLength
        params["cox"] = oxide * w * effectiveLength
        params["cgs"] = (spice["CGSO"] ?? 0) * w
        params["cgd"] = (spice["CGDO"] ?? 0) * w
        params["cgb"] = (spice["CGBO"] ?? 0) * effectiveLength
        // the bulk junctions from their areas, when the card gives them per area
        if spice["CBD"] == nil, let cj = spice["CJ"] { params["cbd"] = cj * ad }
        if spice["CBS"] == nil, let cj = spice["CJ"] { params["cbs"] = cj * sourceArea }
        if let js = spice["JS"], js > 0, ad > 0, sourceArea > 0 { params["saturationCurrent"] = js * ad }
        // the drain and source resistances, or the sheet's
        if spice["RD"] == nil, let rsh = spice["RSH"], rsh > 0 { params["rd"] = rsh * nrd }
        if spice["RS"] == nil, let rsh = spice["RSH"], rsh > 0 { params["rs"] = rsh * nrs }
        let worked: Set<String> = ["VTO", "VT0", "KP", "TOX", "U0", "UO", "NSUB", "TPG", "NSS", "LD", "CGSO", "CGDO", "CGBO", "CJ",
                                   "JS", "RSH"]
        let known = Set(Self.card.map(\.spice)).union(worked)
        let left = spice.filter { !known.contains($0.key) && Self.ignored[$0.key] != $0.value }.map(\.key).sorted()
        return (params, left)
    }

    /// A MOSFET's parameters (`value` reads them) as the body of a `.model` card for a transistor with W and L of 1 m,
    /// so that KP is its beta and the overlap and oxide capacitances its own
    static func cardText(_ value: (String) -> Double, kind: ElementKind) -> String {
        let type: Double = kind == .pmos ? -1 : 1
        var words = ["LEVEL=1", "VTO=\(String(format: "%.6g", type * value("threshold")))",
                     "KP=\(String(format: "%.6g", value("beta")))"]
        for (name, key) in Self.card {
            let v = value(key)
            let standard = spiceDefaults[key] ?? kind.params.first { $0.key == key }?.defaultValue ?? 0
            if v != standard || name == "LAMBDA" { words.append("\(name)=\(String(format: "%.6g", v))") }
        }
        for (name, key) in [("CGSO", "cgs"), ("CGDO", "cgd"), ("CGBO", "cgb")] where value(key) > 0 {
            words.append("\(name)=\(String(format: "%.6g", value(key)))")
        }
        if value("cox") > 0 { words.append("TOX=\(String(format: "%.6g", 3.9 * 8.854214871e-12 / value("cox")))") }
        return words.joined(separator: " ")
    }
}
