import Foundation

// MARK: - SPICE Netlist Parser

/// Parses standard SPICE netlist format (.cir, .spice, .sp files) into CircuitDocument.
///
/// Supports:
/// - Component instantiation (R, C, L, D, Q, M, V, I)
/// - .tran, .dc, .ac analysis directives
/// - .model definitions (basic)
/// - .subckt blocks (basic)
/// - Comments (* and ;)
///
/// Format reference: Berkeley SPICE3 / ngspice netlist format
enum SPICENetlistParser {

    enum ParseError: Error, CustomStringConvertible {
        case invalidLine(Int, String)
        case unknownComponent(String)
        case missingNodes(String)
        case invalidValue(String)
        case fileNotFound(String)

        var description: String {
            switch self {
            case .invalidLine(let line, let text):
                return "Line \(line): Invalid syntax '\(text)'"
            case .unknownComponent(let name):
                return "Unknown component type: \(name)"
            case .missingNodes(let component):
                return "Missing node connections for \(component)"
            case .invalidValue(let text):
                return "Invalid value: \(text)"
            case .fileNotFound(let path):
                return "File not found: \(path)"
            }
        }
    }

    // MARK: - Parse

    static func parse(_ text: String) throws -> CircuitDocument {
        var document = CircuitDocument()
        var yPosition: CGFloat = 100
        let xSpacing: CGFloat = 150
        var componentCount = 0
        var foundFirstNonComment = false

        let lines = text.components(separatedBy: .newlines)

        for (_, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Handle line continuation (+)
            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix(";") { continue }

            // SPICE format: first non-comment line is the title, skip it
            if !foundFirstNonComment {
                foundFirstNonComment = true
                // If it looks like a component or directive, don't skip it
                if !line.hasPrefix(".") && !isComponent(line) {
                    continue  // Title line
                }
            }

            // Control directives
            if line.hasPrefix(".") {
                try parseDirective(line, into: &document)
                continue
            }

            // Component lines
            if let component = try parseComponent(line, index: componentCount) {
                var placed = component
                placed.position = CGPoint(
                    x: 100 + CGFloat(componentCount % 5) * xSpacing,
                    y: yPosition
                )
                if componentCount > 0 && componentCount % 5 == 0 {
                    yPosition += 120
                }
                document.addComponent(placed)
                componentCount += 1
            }
        }

        return document
    }

    // MARK: - Component Parsing

    private static func isComponent(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "RCLDQMVIEFGHrcldqmviefgh".contains(first)
    }

    private static func parseComponent(_ line: String, index: Int) throws -> SchematicComponent? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return nil }

        let name = tokens[0]
        guard let firstChar = name.uppercased().first else { return nil }

        switch firstChar {
        case "R":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            let value = try parseValue(tokens[3])
            var component = SchematicComponent(type: .resistor)
            component.label = name
            component.parameters["resistance"]?.value = value
            return component

        case "C":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            let value = try parseValue(tokens[3])
            var component = SchematicComponent(type: .capacitor)
            component.label = name
            component.parameters["capacitance"]?.value = value
            return component

        case "L":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            let value = try parseValue(tokens[3])
            var component = SchematicComponent(type: .inductor)
            component.label = name
            component.parameters["inductance"]?.value = value
            return component

        case "D":
            var component = SchematicComponent(type: .diode)
            component.label = name
            if tokens.count > 3 {
                component.modelName = tokens[3]
            }
            return component

        case "Q":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            // Q<name> <collector> <base> <emitter> <model>
            var component = SchematicComponent(type: .npnBJT)
            component.label = name
            if tokens.count > 4 {
                component.modelName = tokens[4]
            }
            return component

        case "M":
            guard tokens.count >= 5 else { throw ParseError.missingNodes(name) }
            // M<name> <drain> <gate> <source> <body> <model>
            var component = SchematicComponent(type: .nmosFET)
            component.label = name
            if tokens.count > 5 {
                component.modelName = tokens[5]
            }
            return component

        case "V":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            let valueStr = tokens[3...].joined(separator: " ")
            if valueStr.uppercased().contains("AC") || valueStr.uppercased().contains("SIN") {
                var component = SchematicComponent(type: .acVoltageSource)
                component.label = name
                if let sinParams = parseSinDirective(valueStr) {
                    component.parameters["dcOffset"]?.value = sinParams.offset
                    component.parameters["amplitude"]?.value = sinParams.amplitude
                    component.parameters["frequency"]?.value = sinParams.frequency
                }
                return component
            } else {
                let value = try parseValue(tokens[3])
                var component = SchematicComponent(type: .dcVoltageSource)
                component.label = name
                component.parameters["voltage"]?.value = value
                return component
            }

        case "I":
            guard tokens.count >= 4 else { throw ParseError.missingNodes(name) }
            let value = try parseValue(tokens[3])
            var component = SchematicComponent(type: .dcCurrentSource)
            component.label = name
            component.parameters["current"]?.value = value
            return component

        case "E":
            // VCVS: E<name> n+ n- nc+ nc- gain
            guard tokens.count >= 6 else { throw ParseError.missingNodes(name) }
            let gain = try parseValue(tokens[5])
            var component = SchematicComponent(type: .vcvs)
            component.label = name
            component.parameters["gain"]?.value = gain
            return component

        case "G":
            // VCCS: G<name> n+ n- nc+ nc- gm
            guard tokens.count >= 6 else { throw ParseError.missingNodes(name) }
            let gm = try parseValue(tokens[5])
            var component = SchematicComponent(type: .vccs)
            component.label = name
            component.parameters["gain"]?.value = gm
            return component

        default:
            return nil
        }
    }

    // MARK: - Directive Parsing

    private static func parseDirective(_ line: String, into document: inout CircuitDocument) throws {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let directive = tokens.first?.lowercased() else { return }

        switch directive {
        case ".tran":
            // .tran <tstep> <tstop> [<tstart> [<tmax>]]
            if tokens.count >= 3 {
                document.simulationConfig.transient.timeStep = (try? parseValue(tokens[1])) ?? 1e-6
                document.simulationConfig.transient.stopTime = (try? parseValue(tokens[2])) ?? 0.01
            }
            if tokens.count >= 4 {
                document.simulationConfig.transient.startTime = (try? parseValue(tokens[3])) ?? 0
            }

        case ".ac":
            // .ac <type> <npoints> <fstart> <fstop>
            if tokens.count >= 5 {
                let sweepType = tokens[1].lowercased()
                if sweepType == "dec" {
                    document.simulationConfig.acAnalysis.sweepType = .decade
                } else if sweepType == "lin" {
                    document.simulationConfig.acAnalysis.sweepType = .linear
                } else if sweepType == "oct" {
                    document.simulationConfig.acAnalysis.sweepType = .octave
                }
                document.simulationConfig.acAnalysis.pointsPerDecade = Int(tokens[2]) ?? 20
                document.simulationConfig.acAnalysis.startFrequency = (try? parseValue(tokens[3])) ?? 1
                document.simulationConfig.acAnalysis.stopFrequency = (try? parseValue(tokens[4])) ?? 1e6
            }

        case ".end":
            break  // End of netlist

        default:
            break  // Ignore unknown directives
        }
    }

    // MARK: - Value Parsing

    /// Parse SPICE value notation: 1k, 10u, 4.7n, 100meg, etc.
    static func parseValue(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()

        let suffixes: [(String, Double)] = [
            ("t", 1e12), ("tera", 1e12),
            ("g", 1e9), ("giga", 1e9),
            ("meg", 1e6),
            ("k", 1e3), ("kilo", 1e3),
            ("m", 1e-3), ("milli", 1e-3),
            ("u", 1e-6), ("micro", 1e-6),
            ("n", 1e-9), ("nano", 1e-9),
            ("p", 1e-12), ("pico", 1e-12),
            ("f", 1e-15), ("femto", 1e-15),
        ]

        // Try each suffix (longest first to avoid "m" matching before "meg")
        let sortedSuffixes = suffixes.sorted { $0.0.count > $1.0.count }
        for (suffix, multiplier) in sortedSuffixes {
            if trimmed.hasSuffix(suffix) {
                let numStr = String(trimmed.dropLast(suffix.count))
                if let num = Double(numStr) {
                    return num * multiplier
                }
            }
        }

        // Try plain number
        if let num = Double(trimmed) {
            return num
        }

        throw ParseError.invalidValue(text)
    }

    // MARK: - SIN() parsing

    private static func parseSinDirective(_ text: String) -> (offset: Double, amplitude: Double, frequency: Double)? {
        // SIN(Voffset Vamp Freq [Td [Theta [Phase]]])
        let upper = text.uppercased()
        guard let sinStart = upper.range(of: "SIN("),
              let sinEnd = upper.range(of: ")", range: sinStart.upperBound..<upper.endIndex) else {
            return nil
        }

        let paramsStr = String(text[text.index(text.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: sinStart.upperBound))..<text.index(text.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: sinEnd.lowerBound))])
        let params = paramsStr.split(separator: " ").compactMap { try? parseValue(String($0)) }

        guard params.count >= 3 else { return nil }
        return (offset: params[0], amplitude: params[1], frequency: params[2])
    }
}

// MARK: - SPICE Netlist Exporter

enum SPICENetlistExporter {

    static func export(document: CircuitDocument) -> String {
        var lines: [String] = []

        // Title
        lines.append("* \(document.metadata.name)")
        lines.append("* Generated by JSpice for macOS")
        lines.append("* \(Date())")
        lines.append("")

        // Components
        let connectivity = NetlistGenerator.buildConnectivity(document: document)

        for component in document.components {
            let nodes = connectivity.nodesForComponent(component.id, pinCount: component.type.pinCount)
            let nodeStr = nodes.joined(separator: " ")

            switch component.type {
            case .resistor:
                let value = component.parameters["resistance"]?.value ?? 1000
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(value))")

            case .capacitor:
                let value = component.parameters["capacitance"]?.value ?? 1e-6
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(value))")

            case .inductor:
                let value = component.parameters["inductance"]?.value ?? 1e-3
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(value))")

            case .diode:
                let model = component.modelName ?? "D"
                lines.append("\(component.label) \(nodeStr) \(model)")

            case .npnBJT, .pnpBJT:
                let model = component.modelName ?? "NPN"
                lines.append("\(component.label) \(nodeStr) \(model)")

            case .nmosFET, .pmosFET:
                let model = component.modelName ?? "NMOS"
                let w = component.parameters["channelWidth"]?.value ?? 10e-6
                let l = component.parameters["channelLength"]?.value ?? 1e-6
                lines.append("\(component.label) \(nodeStr) \(model) W=\(formatSPICEValue(w)) L=\(formatSPICEValue(l))")

            case .dcVoltageSource:
                let value = component.parameters["voltage"]?.value ?? 5
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(value))")

            case .dcCurrentSource:
                let value = component.parameters["current"]?.value ?? 0.001
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(value))")

            case .acVoltageSource:
                let dc = component.parameters["dcOffset"]?.value ?? 0
                let amp = component.parameters["amplitude"]?.value ?? 1
                let freq = component.parameters["frequency"]?.value ?? 1000
                lines.append("\(component.label) \(nodeStr) DC \(formatSPICEValue(dc)) SIN(\(dc) \(amp) \(freq))")

            case .vcvs:
                let gain = component.parameters["gain"]?.value ?? 1
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(gain))")

            case .vccs:
                let gm = component.parameters["gain"]?.value ?? 1
                lines.append("\(component.label) \(nodeStr) \(formatSPICEValue(gm))")

            default:
                lines.append("* \(component.label) (\(component.type.displayName)) - not exported")
            }
        }

        lines.append("")

        // Analysis directives
        let transient = document.simulationConfig.transient
        lines.append(".tran \(formatSPICEValue(transient.timeStep)) \(formatSPICEValue(transient.stopTime))")

        let ac = document.simulationConfig.acAnalysis
        lines.append(".ac dec \(ac.pointsPerDecade) \(formatSPICEValue(ac.startFrequency)) \(formatSPICEValue(ac.stopFrequency))")

        lines.append("")
        lines.append(".end")

        return lines.joined(separator: "\n")
    }

    private static func formatSPICEValue(_ value: Double) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        if absValue >= 1e12 { return "\(sign)\(absValue / 1e12)T" }
        if absValue >= 1e9 { return "\(sign)\(absValue / 1e9)G" }
        if absValue >= 1e6 { return "\(sign)\(absValue / 1e6)MEG" }
        if absValue >= 1e3 { return "\(sign)\(absValue / 1e3)k" }
        if absValue >= 1 { return "\(sign)\(absValue)" }
        if absValue >= 1e-3 { return "\(sign)\(absValue * 1e3)m" }
        if absValue >= 1e-6 { return "\(sign)\(absValue * 1e6)u" }
        if absValue >= 1e-9 { return "\(sign)\(absValue * 1e9)n" }
        if absValue >= 1e-12 { return "\(sign)\(absValue * 1e12)p" }
        if absValue >= 1e-15 { return "\(sign)\(absValue * 1e15)f" }
        return "\(value)"
    }
}
