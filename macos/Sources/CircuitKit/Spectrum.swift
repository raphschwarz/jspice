import Foundation

/// What frequencies a signal is made of: the amplitude at each frequency (as a sine's peak would read), the
/// fundamental, its harmonics and the total harmonic distortion. Evenly spaced samples are taken through a Hann window
/// and a fast Fourier transform; a harmonic's amplitude is measured from the energy around it, so it reads right
/// wherever it falls between the transform's bins.
public struct Spectrum: Sendable {
    public struct Harmonic: Sendable {
        /// 1 for the fundamental, 2 for the second harmonic…
        public var number: Int
        public var frequency: Double
        public var amplitude: Double
    }

    /// Hz between neighbouring amplitudes
    public var binWidth: Double
    /// The finest detail in frequency the samples hold: one over their duration
    public var resolution: Double
    /// Peak amplitude at 0, binWidth, 2·binWidth… up to `maxFrequency`, in the signal's unit
    public var amplitudes: [Double]
    /// The highest frequency the samples show truly (below half the sample rate and half the simulation's step rate)
    public var maxFrequency: Double
    /// The lowest frequency with a clear peak whose multiples the other peaks are, or nil for a signal without one
    public var fundamental: Double?
    /// The fundamental and its harmonics below `maxFrequency`, up to the tenth
    public var harmonics: [Harmonic]
    /// RMS of the harmonics above the fundamental, divided by the fundamental's (0.01 is 1 %), or nil without one
    public var thd: Double?
    /// RMS of the signal without its mean
    public var rms: Double
    public var mean: Double

    public func frequency(ofBin k: Int) -> Double { Double(k) * binWidth }

    /// The spectrum of `samples`, taken every `interval` seconds (at most the newest million); nil for fewer than 64.
    /// They are windowed as they are and padded with silence to a power of two, which only spaces the bins closer.
    public static func analyze(_ samples: [Double], interval: Double, maxFrequency: Double? = nil, harmonics count: Int = 10) -> Spectrum? {
        guard samples.count >= 64, interval > 0 else { return nil }
        let used = samples.suffix(1 << 20)
        let m = used.count
        var n = 1
        while n < m { n *= 2 }
        // bins per bin of the samples' own resolution
        let spread = Double(n) / Double(m)
        let mean = used.reduce(0, +) / Double(m)
        var sumSquares = 0.0
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        var windowSquares = 0.0
        for (k, value) in used.enumerated() {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(m))
            let x = value - mean
            sumSquares += x * x
            re[k] = w * x
            windowSquares += w * w
        }
        fft(&re, &im)
        let binWidth = 1 / (Double(n) * interval)
        let top = min(maxFrequency ?? .infinity, 0.5 / interval)
        let bins = min(n / 2, Int(top / binWidth))
        guard bins > 8 else { return nil }
        let power = (0...bins).map { re[$0] * re[$0] + im[$0] * im[$0] }
        // a sine of amplitude A on a bin reads A (the window's sum is m / 2)
        let amplitudes = power.map { 4 * $0.squareRoot() / Double(m) }
        let band = Int((3 * spread).rounded(.up))

        /// The amplitude of a tone near bin `centre`, from the energy within three of the samples' own bins of the
        /// strongest bin near it (the window's main lobe and then some)
        func tone(near centre: Double) -> (bin: Int, amplitude: Double) {
            let c = Int(centre.rounded())
            let reach = Int(spread.rounded(.up))
            let low = max(1, c - reach), high = min(bins, c + reach)
            guard low <= high else { return (c, 0) }
            let peak = (low...high).max { power[$0] < power[$1] } ?? c
            var energy = 0.0
            for k in max(1, peak - band)...min(bins, peak + band) { energy += power[k] }
            return (peak, 2 * (energy / (Double(n) * windowSquares)).squareRoot())
        }
        /// The tone's frequency: the centre of its energy, which falls between bins as the tone does
        func centre(_ bin: Int) -> Double {
            var weighted = 0.0, total = 0.0
            let reach = Int((2 * spread).rounded(.up))
            for k in max(1, bin - reach)...min(bins, bin + reach) {
                weighted += Double(k) * power[k]
                total += power[k]
            }
            return total > 0 ? weighted / total : Double(bin)
        }

        var fundamental: Double?
        var harmonics: [Harmonic] = []
        var thd: Double?
        // at least four cycles in the samples, so the fundamental stands clear of the window's own low end
        let lowest = Int((4 * spread).rounded(.up))
        if bins > lowest, let strongest = (lowest...bins).max(by: { power[$0] < power[$1] }), power[strongest] > 0 {
            let strength = tone(near: Double(strongest)).amplitude
            var f0 = centre(strongest)
            // the strongest peak may be a harmonic: take the lowest whole fraction of it that is a clear peak too
            for divisor in [4, 3, 2] {
                let candidate = f0 / Double(divisor)
                guard candidate >= Double(lowest) else { continue }
                let found = tone(near: candidate)
                let local = found.bin > 1 && found.bin < bins && power[found.bin] >= power[found.bin - 1] && power[found.bin] >= power[found.bin + 1]
                if local && found.amplitude > 0.1 * strength {
                    f0 = centre(found.bin)
                    break
                }
            }
            fundamental = f0 * binWidth
            for h in 1...max(1, count) {
                let at = f0 * Double(h)
                guard at + Double(band) <= Double(bins) else { break }
                harmonics.append(Harmonic(number: h, frequency: at * binWidth, amplitude: tone(near: at).amplitude))
            }
            if let first = harmonics.first, first.amplitude > 0 {
                let rest = harmonics.dropFirst().map { $0.amplitude * $0.amplitude }.reduce(0, +)
                thd = rest.squareRoot() / first.amplitude
            }
        }
        return Spectrum(binWidth: binWidth, resolution: 1 / (Double(m) * interval), amplitudes: amplitudes, maxFrequency: Double(bins) * binWidth,
                        fundamental: fundamental, harmonics: harmonics, thd: thd,
                        rms: (sumSquares / Double(m)).squareRoot(), mean: mean)
    }

    /// In-place radix-2 fast Fourier transform; the count must be a power of two
    public static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1, n & (n - 1) == 0, im.count == n else { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wr = cos(angle), wi = sin(angle)
            var start = 0
            while start < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(length / 2) {
                    let a = start + k, b = a + length / 2
                    let tr = re[b] * cr - im[b] * ci
                    let ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                    let next = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = next
                }
                start += length
            }
            length *= 2
        }
    }
}
