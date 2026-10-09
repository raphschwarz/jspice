import Foundation

/// Makers' models JSpice knows where to find: each part's model file as its maker publishes it (the archive's address,
/// the file in it and its SHA-256, so a new revision is noticed), the datasheet its figures are checked against (the
/// document and table, and what it gives), and what ngspice measures on the same file. JSpice ships none of the files
/// (they are the makers' to give out): `MakerModelCatalog.download` fetches one from its maker.
public enum MakerModelCatalog {
    /// What `MakerModels.measureOpAmp` measures, by name
    public enum Figure: String, Sendable, CaseIterable {
        case offset, supplyCurrent, openLoopGain, gainBandwidth, unityGain, phaseMargin, slewRise, slewFall, swingHigh, swingLow

        public var name: String {
            switch self {
            case .offset: return "Input offset voltage"
            case .supplyCurrent: return "Supply current"
            case .openLoopGain: return "Open-loop gain"
            case .gainBandwidth: return "Gain-bandwidth product"
            case .unityGain: return "Unity-gain frequency"
            case .phaseMargin: return "Phase margin"
            case .slewRise: return "Slew rate, rising"
            case .slewFall: return "Slew rate, falling"
            case .swingHigh: return "Output swing, high"
            case .swingLow: return "Output swing, low"
            }
        }

        /// The figure in the units a datasheet gives it: mV, mA, dB, MHz, degrees, V/µs, V
        public func value(_ f: MakerModels.OpAmpFigures) -> Double? {
            switch self {
            case .offset: return f.offset * 1e3
            case .supplyCurrent: return f.supplyCurrent * 1e3
            case .openLoopGain: return f.openLoopGain
            case .gainBandwidth: return f.gainBandwidth.map { $0 / 1e6 }
            case .unityGain: return f.unityGain.map { $0 / 1e6 }
            case .phaseMargin: return f.phaseMargin
            case .slewRise: return f.slewRise.map { $0 / 1e6 }
            case .slewFall: return f.slewFall.map { $0 / 1e6 }
            case .swingHigh: return f.swingHigh
            case .swingLow: return f.swingLow
            }
        }

        public var unit: String {
            switch self {
            case .offset: return "mV"
            case .supplyCurrent: return "mA"
            case .openLoopGain: return "dB"
            case .gainBandwidth, .unityGain: return "MHz"
            case .phaseMargin: return "°"
            case .slewRise, .slewFall: return "V/µs"
            case .swingHigh, .swingLow: return "V"
            }
        }
    }

    /// What a datasheet gives for a figure: its typical value (an offset's magnitude), or a limit it guarantees
    public struct DatasheetValue: Sendable {
        public enum Kind: Sendable { case typical, atLeast, atMost }
        public var figure: Figure
        public var value: Double
        public var kind: Kind
        /// Where it is given, and for which of the part's grades
        public var note: String

        public init(_ figure: Figure, _ value: Double, _ kind: Kind = .typical, _ note: String = "") {
            self.figure = figure
            self.value = value
            self.kind = kind
            self.note = note
        }
    }

    public struct Model: Sendable, Identifiable {
        public var id: String { part }
        public var part: String
        public var maker: String
        public var summary: String
        /// The maker's archive of the model, the model file in it, and that file's SHA-256 and revision
        public var archive: URL
        public var file: String
        public var sha256: String
        public var revision: String
        public var subcircuit: String
        /// The supplies (±) and load of the datasheet's table, to measure at
        public var supply: Double
        public var load: Double
        /// The gain the datasheet measures the slew rate at: +1 (a follower) or −1 (an inverting stage)
        public var slewGain: Double = 1
        /// The datasheet: its document (with revision), table, and address
        public var datasheet: String
        public var datasheetURL: URL
        public var figures: [DatasheetValue]
        /// ngspice measuring the same file the same way (`tools/spice-reference/maker_models.py`), in datasheet units
        public var ngspice: [Figure: Double]
        /// What the model is known to get wrong against its datasheet, found by measuring it
        public var notes: [String]
    }

    public static let models: [Model] = [
        Model(part: "TL072", maker: "Texas Instruments",
              summary: "JFET-input dual op-amp: TI's 1989 Boyle macromodel of the original TL07x die",
              archive: URL(string: "https://www.ti.com/lit/zip/SLOJ067")!, file: "TL072.301",
              sha256: "74e89d558163615ac7a19f0c783101a6f8af77fb6d80bd3c20c6ab66426561cd",
              revision: "PARTS release 4.01, 16 June 1989", subcircuit: "TL072", supply: 15, load: 10_000,
              datasheet: "SLOS080W (July 2025), tables 5.8 and 5.9, TL07xC",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/tl072.pdf")!,
              figures: [
                  DatasheetValue(.offset, 3, .typical, "VOS, TL07xC"),
                  DatasheetValue(.supplyCurrent, 1.4, .typical, "IQ per amplifier"),
                  DatasheetValue(.openLoopGain, 106, .typical, "AOL 200 V/mV"),
                  DatasheetValue(.gainBandwidth, 3, .typical, "GBW, NS and PS packages and TL07xM; 5.25 MHz for all others"),
                  DatasheetValue(.phaseMargin, 56, .typical, "G = +1, RL = 10 kΩ, CL = 20 pF"),
                  DatasheetValue(.slewRise, 20, .typical, "SR, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.slewFall, 20, .typical, "SR, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.swingHigh, 13.5, .typical, "VOM, RL = 10 kΩ"),
                  DatasheetValue(.swingLow, -13.5, .typical, "VOM, RL = 10 kΩ"),
              ],
              ngspice: [.offset: 0.0109707, .supplyCurrent: 14.1941, .openLoopGain: 106.705, .gainBandwidth: 3.34616,
                        .unityGain: 3.04148, .phaseMargin: 63.889, .slewRise: 12.8246, .slewFall: 13.1229, .swingHigh: 13.4302,
                        .swingLow: -13.4302],
              notes: [
                  "It models the original die: 3.3 MHz and 13 V/µs, where today's TL07xC is 5.25 MHz and 20 V/µs (the datasheet keeps 3 MHz for the NS and PS packages and the TL07xM).",
                  "It draws 14.2 mA from the supplies, ten times the datasheet's 1.4 mA: its RP is 2.143 kΩ across them.",
                  "It has no input offset to speak of (11 µV), where the datasheet's typical is 3 mV.",
              ]),
        Model(part: "OPA1678", maker: "Texas Instruments",
              summary: "Low-noise audio dual op-amp (OPA167x): a Green-Williams-Lis macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SBOMAC3")!, file: "OPA167x.LIB",
              sha256: "a4a2f63b714c799bd4ccbf52fa71922d2786f93fcdfcc10f0b11377194beef77",
              revision: "Final 1.7, 24 August 2022 (SBOMAC3E)", subcircuit: "OPA167x", supply: 15, load: 2_000, slewGain: -1,
              datasheet: "SBOS855E (December 2022), table 6.7",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/opa1678.pdf")!,
              figures: [
                  DatasheetValue(.offset, 0.5, .typical, "VOS ±0.5 mV"),
                  DatasheetValue(.supplyCurrent, 2, .typical, "IQ per channel"),
                  DatasheetValue(.openLoopGain, 114, .typical, "AOL, (V–) + 0.8 V ≤ VO ≤ (V+) – 0.8 V"),
                  DatasheetValue(.gainBandwidth, 16, .typical, "GBW, G = 1"),
                  DatasheetValue(.slewRise, 9, .typical, "SR, G = –1"),
                  DatasheetValue(.slewFall, 9, .typical, "SR, G = –1"),
                  DatasheetValue(.swingHigh, 14.2, .atLeast, "VO up to (V+) – 0.8 V"),
                  DatasheetValue(.swingLow, -14.2, .atMost, "VO down to (V–) + 0.8 V"),
              ],
              ngspice: [.offset: 0.499397, .supplyCurrent: 2.00025, .openLoopGain: 119.708, .gainBandwidth: 17.4125,
                        .unityGain: 23.2092, .phaseMargin: 73.4824, .slewRise: 8.76035, .slewFall: 8.76027, .swingHigh: 13.8805,
                        .swingLow: -13.701],
              notes: [
                  "Into 2 kΩ its output swings to 1.1 V from the positive supply and 1.3 V from the negative, where the datasheet's output range reaches 0.8 V from either.",
                  "Its open-loop gain into 2 kΩ is 119.7 dB, where the datasheet's typical is 114 dB.",
              ]),
        Model(part: "OPA2134", maker: "Texas Instruments",
              summary: "FET-input audio dual op-amp (OPAx134): a Green-Williams-Lis macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SBOM042")!, file: "OPAx134.LIB",
              sha256: "8ff414c678a7f8330b87504d7e0553de20ca87bdc713cecf81ab3448b4d7608f",
              revision: "Final 1.4, 1 July 2022 (SBOM042F), made from datasheet SBOS058A", subcircuit: "OPAx134",
              supply: 15, load: 2_000,
              datasheet: "SBOS058B (November 2024), table 5.7",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/opa2134.pdf")!,
              figures: [
                  DatasheetValue(.offset, 1, .typical, "VOS ±1 mV"),
                  DatasheetValue(.supplyCurrent, 4, .typical, "IQ per amplifier"),
                  DatasheetValue(.openLoopGain, 120, .typical, "AOL, RL = 2 kΩ"),
                  DatasheetValue(.gainBandwidth, 8, .typical, "GBW"),
                  DatasheetValue(.slewRise, 20, .typical, "SR ±20 V/µs"),
                  DatasheetValue(.slewFall, 20, .typical, "SR ±20 V/µs"),
                  DatasheetValue(.swingHigh, 13.5, .atLeast, "VO, RL = 2 kΩ: (V+) – 1.5 V"),
                  DatasheetValue(.swingLow, -13.8, .atMost, "VO, RL = 2 kΩ: (V–) + 1.2 V"),
              ],
              ngspice: [.offset: 0.500004, .supplyCurrent: 4.00027, .openLoopGain: 124.013, .gainBandwidth: 7.83183,
                        .unityGain: 7.72596, .phaseMargin: 54.499, .slewRise: 19.8438, .slewFall: 19.8435, .swingHigh: 13.6956,
                        .swingLow: -14.0683],
              notes: ["Made from the 2015 datasheet (SBOS058A); its figures agree with the 2024 one's."]),
        Model(part: "OPA1612", maker: "Texas Instruments",
              summary: "Bipolar-input, very-low-noise audio dual op-amp (OPA161x): a Green-Williams-Lis macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SBOM396")!, file: "OPA161x.LIB",
              sha256: "c86df5d4b2d26ec196c0a6158a61004a6747aec5440fcc2031674ad62a448ef7",
              revision: "Final 1.5, 24 August 2022, made from datasheet SBOS450C", subcircuit: "OPA161x",
              supply: 15, load: 2_000, slewGain: -1,
              datasheet: "SBOS450C (August 2014), section 6.4",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/opa1612.pdf")!,
              figures: [
                  DatasheetValue(.offset, 0.1, .typical, "VOS ±100 µV at ±15 V"),
                  DatasheetValue(.supplyCurrent, 3.6, .typical, "IQ per channel"),
                  DatasheetValue(.openLoopGain, 114, .typical, "AOL, RL = 2 kΩ, (V–) + 0.6 V ≤ VO ≤ (V+) – 0.6 V"),
                  DatasheetValue(.gainBandwidth, 80, .typical, "GBW, G = 100"),
                  DatasheetValue(.slewRise, 27, .typical, "SR, G = –1"),
                  DatasheetValue(.slewFall, 27, .typical, "SR, G = –1"),
                  DatasheetValue(.swingHigh, 14.4, .atLeast, "VOUT, RL = 2 kΩ: (V+) – 0.6 V"),
                  DatasheetValue(.swingLow, -14.4, .atMost, "VOUT, RL = 2 kΩ: (V–) + 0.6 V"),
              ],
              ngspice: [.offset: 0.100022, .supplyCurrent: 3.60009, .openLoopGain: 112.872, .gainBandwidth: 91.5879,
                        .unityGain: 57.2473, .phaseMargin: 94.2449, .slewRise: 27.1095, .slewFall: 27.0816, .swingHigh: 14.6804,
                        .swingLow: -14.7004],
              notes: ["Its gain-bandwidth product measures 92 MHz (100 times where the gain falls through 40 dB), against the datasheet's 80 MHz at a gain of 100."]),
        Model(part: "RC4558", maker: "Texas Instruments",
              summary: "Dual op-amp, kin of the Tube Screamer's JRC4558: TI's 1989 Boyle macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SLOJ053")!, file: "RC4558.301",
              sha256: "6ff2f51ab04648973e87a854fc0a1ad0dc8ada7c9c3dcc6869c2ab64030246f6",
              revision: "PARTS release 4.01, 8 September 1989", subcircuit: "RC4558", supply: 15, load: 2_000,
              datasheet: "SLOS073H (October 2024), section 5.5",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/rc4558.pdf")!,
              figures: [
                  DatasheetValue(.offset, 0.3, .typical, "VOS"),
                  DatasheetValue(.supplyCurrent, 1.25, .typical, "ICC 2.5 mA for both amplifiers"),
                  DatasheetValue(.openLoopGain, 118, .typical, "AVD 830 V/mV, RL ≥ 2 kΩ"),
                  DatasheetValue(.gainBandwidth, 4, .typical, "GBW, f = 10 kHz"),
                  DatasheetValue(.slewRise, 2.2, .typical, "SR, VSTEP = 10 V, CL = 100 pF"),
                  DatasheetValue(.slewFall, 2.2, .typical, "SR, VSTEP = 10 V, CL = 100 pF"),
                  DatasheetValue(.swingHigh, 13.8, .typical, "VOUT, RL = 2 kΩ"),
                  DatasheetValue(.swingLow, -13.8, .typical, "VOUT, RL = 2 kΩ"),
              ],
              ngspice: [.offset: -0.0101932, .supplyCurrent: 1.25033, .openLoopGain: 109.187, .gainBandwidth: 3.0874,
                        .unityGain: 2.99157, .phaseMargin: 74.421, .slewRise: 1.76722, .slewFall: 1.81042, .swingHigh: 13.0332,
                        .swingLow: -13.0332],
              notes: [
                  "It is the part as the datasheet gave it before its revision H of 2024: 3 MHz, 300 V/mV (109.5 dB) and ±13 V into 2 kΩ, where revision H gives 4 MHz, 830 V/mV (118 dB) and ±13.8 V.",
                  "It slews 1.8 V/µs, where the datasheet's typical is 2.2.",
                  "It has no input offset to speak of (−10 µV), where the datasheet's typical is 0.3 mV.",
              ]),
        Model(part: "UA741", maker: "Texas Instruments",
              summary: "The classic general-purpose op-amp: TI's 1989 Boyle macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SLOJ138")!, file: "UA741.301",
              sha256: "6fc707dc0f43edccf82c22ca3cf582f8fa3e65b3ceb8e73fc6caf6d8679b6f17",
              revision: "PARTS release 4.01, 5 July 1989", subcircuit: "UA741", supply: 15, load: 2_000,
              datasheet: "SLOS094H (February 2026), sections 5.4 and 5.6, µA741C",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/ua741.pdf")!,
              figures: [
                  DatasheetValue(.offset, 0.3, .typical, "VIO"),
                  DatasheetValue(.supplyCurrent, 0.13, .typical, "ICC"),
                  DatasheetValue(.openLoopGain, 106, .typical, "AVD 200 V/mV, RL ≥ 2 kΩ"),
                  DatasheetValue(.slewRise, 0.5, .typical, "SR at unity gain, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.slewFall, 0.5, .typical, "SR at unity gain, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.swingHigh, 10, .atLeast, "VOM, RL = 2 kΩ"),
                  DatasheetValue(.swingLow, -10, .atMost, "VOM, RL = 2 kΩ"),
              ],
              ngspice: [.offset: 0.0111847, .supplyCurrent: 1.66651, .openLoopGain: 105.324, .gainBandwidth: 1.0033,
                        .unityGain: 0.925068, .phaseMargin: 65.8528, .slewRise: 0.520191, .slewFall: 0.507925, .swingHigh: 13.0023,
                        .swingLow: -13.0023],
              notes: [
                  "It is the classic 741: 1.67 mA from the supplies, 1 MHz, ±13 V into 2 kΩ. The 2026 datasheet's typicals are of TI's present die: 0.13 mA, and ±14.95 V into 10 kΩ.",
                  "It has no input offset to speak of (11 µV), where the datasheet's typical is 0.3 mV.",
              ]),
        Model(part: "TL074", maker: "Texas Instruments",
              summary: "JFET-input quad op-amp: TI's 1989 Boyle macromodel, the TL072's",
              archive: URL(string: "https://www.ti.com/lit/zip/SLOJ068")!, file: "TL074.301",
              sha256: "a5f384a32ed660490d7ad57b82ddad836dfcf3b462d9dd8987e8fd4de603b1f3",
              revision: "PARTS release 4.01, 16 June 1989", subcircuit: "TL074", supply: 15, load: 10_000,
              datasheet: "SLOS080W (July 2025), tables 5.8 and 5.9, TL07xC",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/tl074.pdf")!,
              figures: [
                  DatasheetValue(.offset, 3, .typical, "VOS, TL07xC"),
                  DatasheetValue(.supplyCurrent, 1.4, .typical, "IQ per amplifier"),
                  DatasheetValue(.openLoopGain, 106, .typical, "AOL 200 V/mV"),
                  DatasheetValue(.gainBandwidth, 3, .typical, "GBW, NS and PS packages and TL07xM; 5.25 MHz for all others"),
                  DatasheetValue(.phaseMargin, 56, .typical, "G = +1, RL = 10 kΩ, CL = 20 pF"),
                  DatasheetValue(.slewRise, 20, .typical, "SR, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.slewFall, 20, .typical, "SR, RL = 2 kΩ, CL = 100 pF"),
                  DatasheetValue(.swingHigh, 13.5, .typical, "VOM, RL = 10 kΩ"),
                  DatasheetValue(.swingLow, -13.5, .typical, "VOM, RL = 10 kΩ"),
              ],
              ngspice: [.offset: 0.0109707, .supplyCurrent: 14.1941, .openLoopGain: 106.705, .gainBandwidth: 3.34616,
                        .unityGain: 3.04148, .phaseMargin: 63.889, .slewRise: 12.8246, .slewFall: 13.1229, .swingHigh: 13.4302,
                        .swingLow: -13.4302],
              notes: [
                  "It is the TL072 file's model, figure for figure: the original die (3.3 MHz, 13 V/µs), drawing 14.2 mA where the datasheet gives 1.4.",
              ]),
        Model(part: "LM358", maker: "Texas Instruments",
              summary: "Single-supply dual op-amp (LM358, LM2904): a TI macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SNOM268")!, file: "lmx58_lm2904.lib",
              sha256: "467a3e573420d1f5a21fab57b76be0e13073e854f609a73459a191958e314726",
              revision: "Rev. B, 16 November 2018, revised 29 June 2021", subcircuit: "LMX58_LM2904", supply: 15, load: 2_000,
              datasheet: "SLOS068AB (October 2024), section 5.7, LM358",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/lm358.pdf")!,
              figures: [
                  DatasheetValue(.offset, 3, .typical, "VOS, LM358"),
                  DatasheetValue(.supplyCurrent, 0.5, .typical, "IQ per amplifier, VS = 30 V"),
                  DatasheetValue(.openLoopGain, 100, .typical, "AOL 100 V/mV, VS = 15 V, RL ≥ 2 kΩ"),
                  DatasheetValue(.gainBandwidth, 0.7, .typical, "GBW"),
                  DatasheetValue(.slewRise, 0.3, .typical, "SR, G = +1"),
                  DatasheetValue(.slewFall, 0.3, .typical, "SR, G = +1"),
                  DatasheetValue(.swingHigh, 11, .atLeast, "VS = 30 V, RL = 2 kΩ: within 4 V of the positive supply"),
              ],
              ngspice: [.offset: 3.00644, .supplyCurrent: 0.351485, .openLoopGain: 89.5738, .gainBandwidth: 0.699144,
                        .unityGain: 0.658076, .phaseMargin: 54.9609, .slewRise: 0.228818, .slewFall: 0.227094, .swingHigh: 13.5852,
                        .swingLow: -13.9539],
              notes: [
                  "Its open-loop gain is 89.6 dB, where the datasheet's typical is 100 dB (100 V/mV).",
                  "It slews 0.23 V/µs, where the datasheet's typical is 0.3.",
                  "It draws 0.35 mA per amplifier at ±15 V: the datasheet's figure at 5 V (0.5 mA at 30 V).",
              ]),
        Model(part: "OPA1656", maker: "Texas Instruments",
              summary: "CMOS audio dual op-amp, very low noise and distortion: a Green-Williams-Lis macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SBOMAW6")!, file: "OPA1656.LIB",
              sha256: "9847ed60c62e792ee6f1c84899278a3c11ce71a6d21804bdd88f51199f1ba055",
              revision: "Final 1.3, 25 August 2022, made from datasheet SBOS901B", subcircuit: "OPA1656",
              supply: 15, load: 2_000, slewGain: -1,
              datasheet: "SBOS901C (September 2022), section 6.6 (at ±18 V)",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/opa1656.pdf")!,
              figures: [
                  DatasheetValue(.offset, 0.5, .typical, "VOS ±0.5 mV"),
                  DatasheetValue(.supplyCurrent, 3.9, .typical, "IQ per channel"),
                  DatasheetValue(.openLoopGain, 154, .typical, "AOL, RL = 2 kΩ, (V–) + 0.5 V ≤ VO ≤ (V+) – 0.5 V"),
                  DatasheetValue(.gainBandwidth, 53, .typical, "GBW, G = 100"),
                  DatasheetValue(.slewRise, 24, .typical, "SR, G = –1, 10-V step"),
                  DatasheetValue(.slewFall, 24, .typical, "SR, G = –1, 10-V step"),
                  DatasheetValue(.swingHigh, 14.75, .atLeast, "VO up to (V+) – 0.25 V"),
                  DatasheetValue(.swingLow, -14.75, .atMost, "VO down to (V–) + 0.25 V"),
              ],
              ngspice: [.offset: 0.496092, .supplyCurrent: 3.90025, .openLoopGain: 153.726, .gainBandwidth: 52.9259,
                        .unityGain: 20.5598, .phaseMargin: 63.6641, .swingHigh: 14.7404, .swingLow: -14.7946],
              notes: [
                  "ngspice gives up stepping it as an inverting stage driven 10 V (\"timestep too small\", as its overload sensing chatters), so its slew rate is set beside the datasheet's only.",
              ]),
        Model(part: "OPA1642", maker: "Texas Instruments",
              summary: "JFET-input audio dual op-amp (OPA164x): a Green-Williams-Lis macromodel",
              archive: URL(string: "https://www.ti.com/lit/zip/SBOM407")!, file: "OPA164x.LIB",
              sha256: "c3504c5bb927bd66e411e71a3b92e564cf4a6468d94cd6032724ec008938a16c",
              revision: "Final 1.2, 20 January 2022, made from datasheet SBOS484D", subcircuit: "OPA164x",
              supply: 15, load: 2_000,
              datasheet: "SBOS484D (April 2016), section 6.5",
              datasheetURL: URL(string: "https://www.ti.com/lit/ds/symlink/opa1642.pdf")!,
              figures: [
                  DatasheetValue(.offset, 1, .typical, "VOS, VS = ±18 V"),
                  DatasheetValue(.supplyCurrent, 1.8, .typical, "IQ per amplifier"),
                  DatasheetValue(.openLoopGain, 126, .typical, "AOL, RL = 2 kΩ, (V–) + 0.35 V ≤ VO ≤ (V+) – 0.35 V"),
                  DatasheetValue(.gainBandwidth, 11, .typical, "GBW, G = 1"),
                  DatasheetValue(.slewRise, 20, .typical, "SR, G = 1"),
                  DatasheetValue(.slewFall, 20, .typical, "SR, G = 1"),
                  DatasheetValue(.swingHigh, 14.65, .atLeast, "VO, RL = 2 kΩ: (V+) – 0.35 V"),
                  DatasheetValue(.swingLow, -14.65, .atMost, "VO, RL = 2 kΩ: (V–) + 0.35 V"),
              ],
              ngspice: [.offset: 0.999751, .supplyCurrent: 1.8005, .openLoopGain: 124.858, .gainBandwidth: 11.0162,
                        .unityGain: 8.28937, .phaseMargin: 72.3371, .slewRise: 17.2789, .slewFall: 17.3112, .swingHigh: 14.7166,
                        .swingLow: -14.6876],
              notes: [
                  "It slews 17.3 V/µs as a follower, where the datasheet's typical is 20 V/µs at G = 1.",
              ]),
    ]

    public static func model(_ part: String) -> Model? {
        models.first { $0.part.lowercased() == part.lowercased() }
    }

    public enum DownloadError: Error, CustomStringConvertible {
        case notFound(String)
        case revision(String, String)

        public var description: String {
            switch self {
            case let .notFound(file): return "The maker's archive has no \(file)"
            case let .revision(file, sha): return "\(file) is not the revision JSpice knows (its SHA-256 is now \(sha)): the maker has updated it"
            }
        }
    }

    /// The model file from its maker's archive at `archive`, read from `data` (a zip), checked against its SHA-256 unless
    /// `anyRevision`
    public static func modelFile(_ model: Model, fromArchive data: Data, anyRevision: Bool = false) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("archive.zip")
        try data.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", zip.path, "-d", folder.appendingPathComponent("files").path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        let files = FileManager.default.enumerator(at: folder.appendingPathComponent("files"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        guard let found = files.first(where: { $0.lastPathComponent.lowercased() == model.file.lowercased() }) else {
            throw DownloadError.notFound(model.file)
        }
        let file = try Data(contentsOf: found)
        let sha = MakerModels.sha256(file)
        if !anyRevision && sha != model.sha256 { throw DownloadError.revision(model.file, sha) }
        return file
    }

    /// The bytes at `url`, fetched now (a maker's site may turn away a client it does not know: this one says what it is)
    public static func fetch(_ url: URL, timeout: TimeInterval = 60) throws -> Data {
        final class Result: @unchecked Sendable {
            var data: Data?
            var error: Error?
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh) JSpice (a circuit simulator, fetching a maker's SPICE model)",
                         forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result.error = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) from \(url.host ?? "")"])
            } else {
                result.data = data
                result.error = error
            }
            done.signal()
        }
        task.resume()
        // the request's timeout is for a silence: a server that trickles is given up on after three times as long in all
        guard done.wait(timeout: .now() + 3 * timeout) == .success else {
            task.cancel()
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "\(url.host ?? "") took too long"])
        }
        if let error = result.error { throw error }
        return result.data ?? Data()
    }

    /// Downloads the model from its maker and imports it as a block named after the part, its source the maker's
    /// archive (blocking until it is done: call it off the main thread in an app)
    public static func download(_ model: Model, anyRevision: Bool = false) throws -> (block: BlockDefinition, warnings: [String]) {
        let file = try modelFile(model, fromArchive: try fetch(model.archive), anyRevision: anyRevision)
        var imported = try MakerModels.block(from: file, file: model.file, subcircuit: model.subcircuit,
                                             url: model.archive.absoluteString)
        imported.block.name = model.part
        return imported
    }

    /// The figures measured on `model`'s block beside its datasheet's and ngspice's, one line each
    public static func comparison(_ model: Model, _ measured: MakerModels.OpAmpFigures) -> [String] {
        Figure.allCases.compactMap { figure -> String? in
            guard let ours = figure.value(measured) else { return nil }
            var line = String(format: "%@: %.4g %@", figure.name, ours, figure.unit)
            if let sheet = model.figures.first(where: { $0.figure == figure }) {
                let kind = sheet.kind == .typical ? "typical" : sheet.kind == .atLeast ? "at least" : "at most"
                line += String(format: " (datasheet %@ %.4g", kind, sheet.value) + ")"
            }
            if let reference = model.ngspice[figure] { line += String(format: ", ngspice %.4g", reference) }
            return line
        }
    }
}
