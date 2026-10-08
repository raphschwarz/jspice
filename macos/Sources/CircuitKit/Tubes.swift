import Foundation

/// Norman Koren's vacuum tube equations, as in his SPICE models: smooth everywhere, fitted to the published curves of
/// real tubes with a handful of constants. A triode's plate current is
///
///     E1 = Vpk / kp · ln(1 + exp(kp · (1/µ + Vgk / √(kvb + Vpk²))))
///     Ip = 2 · E1^ex / kg1    (0 while E1 ≤ 0)
///
/// A pentode's E1 follows the screen instead of the plate, and the plate only takes its share through atan(Vpk / kvb);
/// the screen draws (Vgk + Vg2k / µ)^ex / kg2. The control grid draws current once it is above the cathode, through
/// about `rgi` (Vgk^1.5 / rgi), which is what makes an overdriven stage bias itself.
public struct TubeModel: Hashable, Sendable {
    public var mu: Double
    public var ex: Double
    public var kg1: Double
    public var kg2: Double
    public var kp: Double
    public var kvb: Double
    public var rgi: Double

    public init(mu: Double = 100, ex: Double = 1.4, kg1: Double = 1060, kg2: Double = 4500, kp: Double = 600, kvb: Double = 300,
                rgi: Double = 2000) {
        self.mu = max(mu, 0.1)
        self.ex = max(ex, 1)
        self.kg1 = max(kg1, 1e-3)
        self.kg2 = max(kg2, 1e-3)
        self.kp = max(kp, 1e-3)
        self.kvb = max(kvb, 1e-6)
        self.rgi = max(rgi, 1)
    }

    /// ln(1 + eᵘ) and its slope, without overflow
    static func softplus(_ u: Double) -> (value: Double, slope: Double) {
        if u > 30 { return (u + log1p(exp(-u)), 1 / (1 + exp(-u))) }
        let e = exp(u)
        return (log1p(e), e / (1 + e))
    }

    /// 2 · E1^ex / kg1 and its slope with E1
    private func power(_ e1: Double) -> (value: Double, slope: Double) {
        guard e1 > 0 else { return (0, 0) }
        let p = pow(e1, ex - 1)
        return (2 * p * e1 / kg1, 2 * ex * p / kg1)
    }

    /// A triode's plate current and its slopes with the grid and plate voltages (both from the cathode)
    public func triode(vgk: Double, vpk: Double) -> (current: Double, dGrid: Double, dPlate: Double) {
        let s2 = kvb + vpk * vpk
        let s = s2.squareRoot()
        let (sp, sigma) = Self.softplus(kp * (1 / mu + vgk / s))
        let e1 = vpk / kp * sp
        guard e1 > 0 else { return (0, 0, 0) }
        let dE1dVg = vpk * sigma / s
        let dE1dVp = sp / kp - vpk * vpk * vgk * sigma / (s2 * s)
        let (ip, dIp) = power(e1)
        return (ip, dIp * dE1dVg, dIp * dE1dVp)
    }

    /// A pentode's plate and screen currents and their slopes with the grid, screen and plate voltages (from the cathode)
    public func pentode(vgk: Double, vsk: Double, vpk: Double)
        -> (plate: Double, plateGrid: Double, plateScreen: Double, platePlate: Double,
            screen: Double, screenGrid: Double, screenScreen: Double) {
        // E1 follows the screen; below a millivolt it is held there (the tube is cut off long before)
        let b = max(vsk, 1e-3)
        let dB: Double = vsk > 1e-3 ? 1 : 0
        let (sp, sigma) = Self.softplus(kp * (1 / mu + vgk / b))
        let e1 = b / kp * sp
        let dE1dVg = sigma
        let dE1dVs = (sp / kp - sigma * vgk / b) * dB
        let (f, dF) = power(e1)
        // the plate's share: atan of its voltage, none while it is below the cathode
        let q = max(vpk, 0)
        let share = atan(q / kvb)
        let dShare = vpk > 0 ? (1 / kvb) / (1 + (q / kvb) * (q / kvb)) : 0
        let plate = f * share
        var screen = 0.0, screenGrid = 0.0, screenScreen = 0.0
        let w = vgk + vsk / mu
        if w > 0 {
            let p = pow(w, ex - 1)
            screen = p * w / kg2
            screenGrid = ex * p / kg2
            screenScreen = screenGrid / mu
        }
        return (plate, dF * dE1dVg * share, dF * dE1dVs * share, f * dShare, screen, screenGrid, screenScreen)
    }

    /// The control grid's current once it is above the cathode, and its slope
    public func grid(vgk: Double) -> (current: Double, slope: Double) {
        guard vgk > 0 else { return (0, 0) }
        let r = vgk.squareRoot()
        return (vgk * r / rgi, 1.5 * r / rgi)
    }
}
