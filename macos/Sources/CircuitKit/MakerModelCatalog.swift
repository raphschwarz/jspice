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
              revision: "Final 1.7, 24 August 2022 (SBOMAC3E)", subcircuit: "OPA167x", supply: 15, load: 2_000,
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
                        .unityGain: 23.2092, .phaseMargin: 73.4824, .slewRise: 7.88953, .slewFall: 7.88894, .swingHigh: 13.8804,
                        .swingLow: -13.7006],
              notes: [
                  "Into 2 kΩ its output swings to 1.1 V from the positive supply and 1.3 V from the negative, where the datasheet's output range reaches 0.8 V from either.",
                  "Its slew rate here is a follower's (7.9 V/µs); the datasheet gives 9 V/µs at a gain of −1.",
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
                        .unityGain: 7.72596, .phaseMargin: 54.499, .slewRise: 19.8438, .slewFall: 19.8435, .swingHigh: 13.6955,
                        .swingLow: -14.0681],
              notes: ["Made from the 2015 datasheet (SBOS058A); its figures agree with the 2024 one's."]),
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
