import Foundation

/// Draws a netlist the way a person would. Signal flows from left to right: sources on the left, each part in a column
/// after the part that feeds it, lined up so the main signal runs along straight lines. Parts to ground hang below the
/// line they leave from, pull-ups stand above it, feedback parts arch over (or under) their op-amp, and a loop back to an
/// earlier stage (an oscillator's) runs along the bottom. Ground connections get ground symbols and supply rails get
/// flags, as on a hand-drawn schematic; every other net is drawn with wires found by a maze router that avoids parts and
/// other nets' pins, crosses other wires only at right angles, and prefers few bends. A net the router cannot draw falls
/// back to labels, so the connections are always right.
public enum SchematicLayout {
    /// Lays out `input` as a new circuit. Parts keep their ids when the netlist gives them.
    public static func layout(_ input: [NetlistPart]) throws -> Circuit {
        let engine = try Engine(input)
        engine.place()
        engine.route()
        return engine.circuit()
    }

    /// The same circuit redrawn tidily: same parts, values, scopes and settings, connections kept
    public static func tidy(_ circuit: Circuit) throws -> Circuit {
        var result = try layout(NetlistExtractor.netlist(from: circuit))
        result.scopes = circuit.scopes.filter { scope in result.elements.contains { $0.id == scope.elementID } }
        result.settings = circuit.settings
        return result
    }

    // MARK: - Tables

    static let inputs: [ElementKind: [String]] = [
        .opAmp: ["minus", "plus"], .ota: ["minus", "plus", "bias"], .timer555: ["trig", "thr", "dis", "ctrl", "reset"],
        .schmittInverter: ["in"], .npn: ["base"], .pnp: ["base"], .nmos: ["gate"], .pmos: ["gate"], .njfet: ["gate"],
        .potentiometer: ["a", "b"], .analogSwitch: ["a", "control"],
    ]
    static let outputs: [ElementKind: [String]] = [
        .opAmp: ["out"], .ota: ["out"], .timer555: ["out"], .schmittInverter: ["out"], .npn: ["collector", "emitter"],
        .pnp: ["collector", "emitter"], .nmos: ["drain", "source"], .pmos: ["drain", "source"], .njfet: ["drain", "source"],
        .potentiometer: ["wiper"], .analogSwitch: ["b"],
    ]
    static let sources: Set<ElementKind> = [.dcVoltage, .acVoltage, .squareVoltage, .currentSource]
    static let amplifiers: Set<ElementKind> = [.opAmp, .ota]

    static func isRailName(_ name: String) -> Bool {
        let s = name.uppercased().replacingOccurrences(of: " ", with: "")
        if s.range(of: #"^[+-]?\d+(\.\d+)?V?$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^V(CC|DD|EE|SS)\d*$"#, options: .regularExpression) != nil { return true }
        return ["V+", "V-", "+V", "-V", "VBAT", "VPOS", "VNEG", "VS"].contains(s)
    }

    static func isNegativeRail(_ name: String) -> Bool {
        let s = name.trimmingCharacters(in: .whitespaces).uppercased()
        return s.hasPrefix("-") || s.hasPrefix("VEE") || s.hasPrefix("VSS") || s == "V-" || s == "VNEG"
    }

    /// Grid points around a part that wires of other nets must avoid (its posts excluded)
    static func keepout(_ e: Element) -> Set<GridPoint> {
        let d = e.axisDirection
        let p = e.perpendicular
        func frame(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Set<GridPoint> {
            var result = Set<GridPoint>()
            for x in xs { for y in ys { result.insert(e.a + d * x + p * y) } }
            return result
        }
        switch e.kind {
        case .ground: return [e.b]
        case .netLabel, .wire: return []
        case .nmos, .pmos, .npn, .pnp, .njfet: return frame(1...2, -1...1)
        case .opAmp, .ota: return frame(0...3, -2...2)
        case .timer555: return frame(0...5, -2...2)
        default:
            let length = abs(e.b.x - e.a.x) + abs(e.b.y - e.a.y)
            var result = Set<GridPoint>()
            if length >= 2 { for k in 1..<length { result.insert(e.a + d * k) } }
            let middle = GridPoint((e.a.x + e.b.x) / 2, (e.a.y + e.b.y) / 2)
            switch e.kind {
            case .acVoltage, .squareVoltage, .currentSource, .probe, .ammeter, .lamp, .capacitor, .dcVoltage,
                 .schmittInverter, .led:
                result.insert(middle + p)
                result.insert(middle - p)
            case .potentiometer, .analogSwitch:
                result.insert(middle - p)
            default:
                break
            }
            return result
        }
    }

    // MARK: - Engine

    private enum NetClass { case ground, rail, signal }

    private enum Role { case source, railSource, directed, series, shunt, railShunt, feedback, bridge, loopBack, inputBridge, orphan }

    private enum Occupant: Equatable {
        case net(String)
        case other
    }

    private enum Orientation { case horizontal, vertical, vertex }

    fileprivate struct RouteState: Hashable {
        let point: GridPoint
        let direction: Int
    }

    private final class Part {
        let id: UUID
        let kind: ElementKind
        var name: String
        let params: [String: Double]
        let closed: Bool
        var connections: [Int: String]
        var role = Role.orphan
        var a: GridPoint?
        var b: GridPoint = .zero
        var flipped = false
        var rank: Int?
        var entered: String?
        var feedbackOf: Part?

        init(_ part: NetlistPart, connections: [Int: String]) {
            id = part.id ?? UUID()
            kind = part.kind
            name = part.name
            var params = part.params
            for spec in part.kind.params where params[spec.key] == nil { params[spec.key] = spec.defaultValue }
            self.params = params
            closed = part.closed
            self.connections = connections
        }

        func net(_ terminal: String) -> String? {
            kind.terminalNames.firstIndex(of: terminal).flatMap { connections[$0] }
        }

        /// Connected nets in terminal order
        var nets: [String] { connections.keys.sorted().compactMap { connections[$0] } }

        var element: Element {
            Element(id: id, kind: kind, name: name, a: a ?? .zero, b: b, params: params, closed: closed, flipped: flipped)
        }

        var posts: [GridPoint] { element.posts }

        func index(of net: String) -> Int? {
            connections.keys.sorted().first { connections[$0] == net }
        }
    }

    private final class Engine {
        var parts: [Part] = []
        var ground = Set<String>()
        var rails = Set<String>()
        var outputNets: [String: Part] = [:]
        var driver: [String: Part] = [:]
        var netRank: [String: Int] = [:]
        var ranked: [Part] = []
        var netY: [String: Int] = [:]
        var occupied: [GridPoint: Occupant] = [:]
        var placed: [Part] = []
        var extra: [Element] = []

        init(_ input: [NetlistPart]) throws {
            for part in input where part.kind != .ground && part.kind != .netLabel && part.kind != .wire {
                var connections: [Int: String] = [:]
                for (terminal, net) in part.connections {
                    guard let index = NetlistLayout.terminalIndex(terminal, of: part.kind) else {
                        throw NetlistError.unknownTerminal(part: part.name, terminal: terminal, valid: part.kind.terminalNames)
                    }
                    let net = net.trimmingCharacters(in: .whitespaces)
                    if !net.isEmpty { connections[index] = net }
                }
                parts.append(Part(part, connections: connections))
            }
            // names: keep the given ones, number the rest
            var used = Set(parts.map(\.name).filter { !$0.isEmpty })
            for part in parts where part.name.isEmpty {
                var k = 1
                while used.contains("\(part.kind.namePrefix)\(k)") { k += 1 }
                part.name = "\(part.kind.namePrefix)\(k)"
                used.insert(part.name)
            }
            classify()
        }

        func cls(_ net: String?) -> NetClass? {
            guard let net else { return nil }
            if ground.contains(net) { return .ground }
            if rails.contains(net) { return .rail }
            return .signal
        }

        func consumers(_ net: String) -> [Part] { parts.filter { $0.connections.values.contains(net) } }

        func inputNets(_ p: Part) -> [String] { (inputs[p.kind] ?? []).compactMap { p.net($0) } }

        func outputNetList(_ p: Part) -> [String] { (outputs[p.kind] ?? []).compactMap { p.net($0) } }

        private func classify() {
            let allNets = Set(parts.flatMap(\.nets))
            ground = allNets.filter { Topology.isGroundName($0) }
            for p in parts where p.kind == .dcVoltage {
                let minus = p.connections[0]
                let plus = p.connections[1]
                if let minus, ground.contains(minus), let plus, !ground.contains(plus) { rails.insert(plus) }
                if let plus, ground.contains(plus), let minus, !ground.contains(minus) { rails.insert(minus) }
            }
            rails.formUnion(allNets.filter { isRailName($0) && !ground.contains($0) })
            let hasDirected = parts.contains { inputs[$0.kind] != nil }
            if !hasDirected {
                // a small passive circuit: draw its supply with wires, like a loop
                rails = rails.filter { rail in parts.reduce(0) { $0 + $1.connections.values.filter { $0 == rail }.count } > 4 }
            }
            for p in parts {
                let count = p.kind.terminalNames.count
                let classes = (0..<count).map { cls(p.connections[$0]) }
                let signals = classes.filter { $0 == .signal }.count
                if sources.contains(p.kind) && count == 2 {
                    if signals > 0 {
                        p.role = .source
                    } else if classes.contains(.rail) {
                        p.role = .railSource
                    } else {
                        p.role = .orphan
                    }
                } else if inputs[p.kind] != nil {
                    p.role = .directed
                } else if count == 2 {
                    if signals == 2 {
                        p.role = .series
                    } else if signals == 1 {
                        p.role = .shunt
                    } else if classes.contains(where: { $0 != nil }) {
                        p.role = .railShunt
                    }
                }
            }
            for p in parts where p.role == .directed {
                for net in outputNetList(p) where cls(net) == .signal && outputNets[net] == nil { outputNets[net] = p }
            }
            // feedback: a part from an amplifier's input to its own output
            for p in parts where p.role == .series {
                guard let n0 = p.connections[0], let n1 = p.connections[1] else { continue }
                for amp in parts where amp.role == .directed
                    && (amplifiers.contains(amp.kind) || amp.kind.isTransistor || amp.kind == .schmittInverter) {
                    let ins = Set(inputNets(amp))
                    let outs = Set(outputNetList(amp))
                    if (ins.contains(n0) && outs.contains(n1)) || (ins.contains(n1) && outs.contains(n0)) {
                        p.role = .feedback
                        p.feedbackOf = amp
                        break
                    }
                }
            }
        }

        // MARK: Ranks

        private func outputsOf(_ p: Part) -> [String] {
            switch p.role {
            case .source:
                if let plus = p.connections[1], cls(plus) == .signal { return [plus] }
                return p.connections[0].map { [$0] } ?? []
            case .series:
                return p.nets.filter { $0 != p.entered }
            case .directed:
                return outputNetList(p)
            default:
                return []
            }
        }

        private func rankParts() {
            var queue: [Part] = []
            func assign(_ p: Part, _ rank: Int, via: String?) {
                guard p.rank == nil else { return }
                p.rank = rank
                p.entered = via
                queue.append(p)
                ranked.append(p)
            }
            var seeds = parts.filter { $0.role == .source }
            if seeds.isEmpty, let first = parts.first(where: { $0.role == .directed }) ?? parts.first(where: { $0.role == .series }) {
                seeds = [first]
            }
            for seed in seeds { assign(seed, 0, via: nil) }
            while true {
                while !queue.isEmpty {
                    let p = queue.removeFirst()
                    let r = p.rank ?? 0
                    for net in outputsOf(p) {
                        guard cls(net) == .signal, netRank[net] == nil else { continue }
                        // a series part does not drive a net an amplifier drives
                        if p.role == .series, let amp = outputNets[net], amp !== p { continue }
                        netRank[net] = r
                        driver[net] = p
                        for q in consumers(net) where q.rank == nil {
                            switch q.role {
                            case .series:
                                let other = q.nets.first { $0 != net }
                                if let other, outputNets[other] != nil {
                                    q.role = .bridge
                                } else if let other, consumers(other).contains(where: { c in
                                    c.rank != nil && c.role == .directed && inputNets(c).contains(other)
                                }) {
                                    q.role = .loopBack
                                } else {
                                    assign(q, r + 1, via: net)
                                }
                            case .directed:
                                if inputNets(q).contains(net) { assign(q, r + 1, via: net) }
                            default:
                                break
                            }
                        }
                    }
                }
                guard let rest = parts.first(where: { $0.rank == nil && ($0.role == .directed || $0.role == .source) }) else { break }
                // another independent group, after the others
                assign(rest, (ranked.compactMap(\.rank).max() ?? -1) + 1, via: nil)
            }
            for p in parts where p.role == .series && p.rank == nil {
                let r0 = p.connections[0].flatMap { netRank[$0] }
                let r1 = p.connections[1].flatMap { netRank[$0] }
                if r0 != nil && r1 != nil {
                    p.role = .bridge
                } else if r0 == nil && r1 == nil {
                    p.role = .inputBridge
                } else {
                    p.role = .loopBack
                }
            }
        }

        // MARK: Placement

        private func cells(_ p: Part, _ a: GridPoint, _ b: GridPoint, _ flipped: Bool) -> [GridPoint: Occupant] {
            var result: [GridPoint: Occupant] = [:]
            let element = Element(kind: p.kind, a: a, b: b, flipped: flipped)
            let posts = element.posts
            for (i, point) in posts.enumerated() {
                result[point] = p.connections[i].map { .net($0) } ?? .other
            }
            for point in keepout(element) where result[point] == nil { result[point] = .other }
            // room for the ground symbol or supply flag on such pins
            let all = posts + [a, b]
            let cx = Double(all.map(\.x).reduce(0, +)) / Double(all.count)
            let cy = Double(all.map(\.y).reduce(0, +)) / Double(all.count)
            for (i, point) in posts.enumerated() {
                guard let net = p.connections[i], cls(net) != .signal else { continue }
                let dx = Double(point.x) - cx
                let dy = Double(point.y) - cy
                let d = abs(dx) >= abs(dy) ? GridPoint(dx >= 0 ? 1 : -1, 0) : GridPoint(0, dy >= 0 ? 1 : -1)
                for k in 1...2 where result[point + d * k] == nil { result[point + d * k] = .other }
            }
            return result
        }

        private func fits(_ p: Part, _ a: GridPoint, _ b: GridPoint, _ flipped: Bool) -> Bool {
            for (point, occupant) in cells(p, a, b, flipped) {
                guard let existing = occupied[point] else { continue }
                if case .net(let mine) = occupant, case .net(let theirs) = existing, mine == theirs { continue }
                return false
            }
            return true
        }

        /// Places `p` at a–b, or as near as fits in the direction `step`
        private func put(_ p: Part, _ a: GridPoint, _ b: GridPoint, flipped: Bool = false, step: GridPoint = GridPoint(0, 1)) {
            var a = a
            var b = b
            for _ in 0..<40 {
                if fits(p, a, b, flipped) { break }
                a = a + step
                b = b + step
            }
            p.a = a
            p.b = b
            p.flipped = flipped
            placed.append(p)
            for (point, occupant) in cells(p, a, b, flipped) where occupied[point] == nil { occupied[point] = occupant }
            for (i, point) in p.posts.enumerated() {
                if let net = p.connections[i], netY[net] == nil, cls(net) == .signal { netY[net] = point.y }
            }
        }

        /// Places a two-terminal part with terminal `first` at `from` and the other at `to`
        private func putTwo(_ p: Part, first: Int, _ from: GridPoint, _ to: GridPoint, step: GridPoint = GridPoint(0, 1)) {
            if first == 0 { put(p, from, to, step: step) } else { put(p, to, from, step: step) }
        }

        func place() {
            rankParts()
            var columns: [Int: [Part]] = [:]
            for p in ranked { columns[p.rank ?? 0, default: []].append(p) }
            var shunts: [String: [Part]] = [:]
            for p in parts where p.role == .shunt {
                if let net = p.nets.first(where: { cls($0) == .signal }) { shunts[net, default: []].append(p) }
            }
            var feedbacks: [ObjectIdentifier: [Part]] = [:]
            for p in parts where p.role == .feedback {
                if let amp = p.feedbackOf { feedbacks[ObjectIdentifier(amp), default: []].append(p) }
            }
            var x = 0
            // supplies on the far left
            for p in parts where p.role == .railSource {
                put(p, GridPoint(x, 4), GridPoint(x, 0))
                x += 4
            }
            if parts.contains(where: { $0.role == .railSource }) { x += 2 }
            var taps: [String: [Int]] = [:]
            for r in columns.keys.sorted() {
                let column = columns[r] ?? []
                // undriven input nets of this column's parts (a 555's timing network) get room on the left
                var leftNets: [String] = []
                for p in column where p.role == .directed {
                    for net in inputNets(p) where cls(net) == .signal && driver[net] == nil && !leftNets.contains(net) {
                        if shunts[net] != nil || parts.contains(where: { $0.role == .inputBridge && $0.nets.contains(net) }) {
                            leftNets.append(net)
                        }
                    }
                }
                var leftX = x
                if !leftNets.isEmpty {
                    x += 2
                    leftX = x
                    x += 3
                }
                var right = x
                for p in column {
                    let via = p.entered
                    let vy = via.flatMap { netY[$0] } ?? 0
                    var width = 4
                    switch p.kind {
                    case _ where p.role == .source:
                        put(p, GridPoint(x, vy + 4), GridPoint(x, vy))
                        width = 0
                    case _ where p.role == .series:
                        let first = via.flatMap { p.index(of: $0) } ?? 0
                        putTwo(p, first: first, GridPoint(x, vy), GridPoint(x + 4, vy))
                    case .opAmp, .ota:
                        let minus = p.net("minus")
                        let plus = p.net("plus")
                        let top: String
                        if via != nil && via == plus {
                            top = "plus"
                        } else if via != nil && via == minus {
                            top = "minus"
                        } else {
                            top = cls(minus) != .signal && cls(plus) == .signal ? "plus" : "minus"
                        }
                        let ay = via != nil ? vy + 1 : 0
                        put(p, GridPoint(x, ay), GridPoint(x + 4, ay), flipped: top == "plus")
                    case .npn, .pnp, .nmos, .pmos, .njfet:
                        put(p, GridPoint(x, vy), GridPoint(x + 2, vy))
                        width = 2
                    case .timer555:
                        put(p, GridPoint(x + 3, vy - 3), GridPoint(x + 3, vy + 2))
                        width = 6
                    case .potentiometer:
                        put(p, GridPoint(x, vy - 2), GridPoint(x, vy + 2))
                        width = 2
                    default:
                        put(p, GridPoint(x, vy), GridPoint(x + 4, vy))
                    }
                    right = max(right, x + width)
                }
                if !leftNets.isEmpty {
                    for net in leftNets {
                        let ys = column.flatMap { q in q.posts.enumerated().filter { q.connections[$0.offset] == net }.map { $0.element.y } }
                        if let y = ys.min() { netY[net] = y }
                    }
                    for q in parts where q.role == .inputBridge && q.a == nil && Set(q.nets).isSubset(of: leftNets) {
                        guard let n0 = q.connections[0], let n1 = q.connections[1] else { continue }
                        let y0 = netY[n0] ?? 0
                        let y1 = netY[n1] ?? 0
                        let top = y0 <= y1 ? 0 : 1
                        let yTop = min(y0, y1)
                        putTwo(q, first: top, GridPoint(leftX, yTop), GridPoint(leftX, yTop + 4))
                        if let topNet = q.connections[top], let bottomNet = q.connections[1 - top] {
                            netY[topNet] = yTop
                            netY[bottomNet] = yTop + 4
                            taps[topNet] = [leftX]
                            taps[bottomNet] = [leftX]
                        }
                    }
                    for net in leftNets where taps[net] == nil { taps[net] = [leftX] }
                }
                // parts to ground (or up to a supply) from the nets this column drives go just right of it
                var shuntX = right + 2
                for p in column where !p.kind.isTransistor {
                    for net in outputsOf(p) where driver[net] === p {
                        let list = shunts[net] ?? []
                        let ups = list.filter { s in
                            guard let other = s.nets.first(where: { $0 != net }) else { return false }
                            return cls(other) == .rail && !isNegativeRail(other)
                        }.count
                        for _ in 0..<max(ups, list.count - ups) {
                            taps[net, default: []].append(shuntX)
                            shuntX += 2
                        }
                    }
                }
                x = max(shuntX, right + 3) + 1
                // feedback over (or under) its amplifier, on the side of the input it returns to
                for p in column {
                    var above = 0
                    var below = 0
                    for f in feedbacks[ObjectIdentifier(p)] ?? [] {
                        guard let pa = p.a else { continue }
                        let outs = Set(outputNetList(p))
                        guard let inputNet = f.nets.first(where: { !outs.contains($0) }), let first = f.index(of: inputNet) else { continue }
                        let posts = p.posts
                        let inputPin = posts.enumerated().first { p.connections[$0.offset] == inputNet }?.element
                        let reference = amplifiers.contains(p.kind) ? pa.y : p.b.y
                        let topSide = inputPin.map { $0.y <= reference } ?? true
                        let y: Int
                        let step: GridPoint
                        if topSide {
                            y = (posts.map(\.y).min() ?? 0) - 2 - 2 * above
                            above += 1
                            step = GridPoint(0, -1)
                        } else {
                            y = (posts.map(\.y).max() ?? 0) + 2 + 2 * below
                            below += 1
                            step = GridPoint(0, 1)
                        }
                        putTwo(f, first: first, GridPoint(pa.x, y), GridPoint(pa.x + 4, y), step: step)
                    }
                }
            }
            // shunts
            for net in shunts.keys.sorted() {
                let list = shunts[net] ?? []
                let xs = taps[net] ?? []
                let drv = driver[net]
                var driverPin: GridPoint?
                if let drv, drv.a != nil {
                    for (i, point) in drv.posts.enumerated() where drv.connections[i] == net { driverPin = point }
                }
                var slots: [Bool: Int] = [true: 0, false: 0]
                for s in list {
                    let ny = netY[net] ?? 0
                    guard let signal = s.index(of: net) else { continue }
                    let other = s.connections[1 - signal]
                    let down = !(other.map { cls($0) == .rail && !isNegativeRail($0) } ?? false)
                    let step = down ? GridPoint(0, 1) : GridPoint(0, -1)
                    // straight on a transistor's collector or emitter when it points the same way
                    if let drv, let pin = driverPin, drv.kind.isTransistor, slots[down] == 0, let da = drv.a {
                        let cy = Double(da.y + drv.b.y) / 2
                        let pointsDown = Double(pin.y) > cy
                        let pointsUp = Double(pin.y) < cy
                        if (down && pointsDown) || (!down && pointsUp) {
                            slots[down, default: 0] += 1
                            putTwo(s, first: signal, pin, pin + step * 4, step: step)
                            continue
                        }
                    }
                    let i = slots[down] ?? 0
                    slots[down] = i + 1
                    let sx: Int
                    if i < xs.count {
                        sx = xs[i]
                    } else if let last = xs.last {
                        sx = last + 2 * (i - xs.count + 1)
                    } else {
                        sx = x + 2 * i
                    }
                    putTwo(s, first: signal, GridPoint(sx, ny), GridPoint(sx, ny) + step * 4, step: GridPoint(1, 0))
                }
            }
            // bridges over the top, loops back along the bottom
            for p in parts where p.a == nil && (p.role == .bridge || p.role == .loopBack || p.role == .inputBridge) {
                guard let n0 = p.connections[0], let n1 = p.connections[1] else { continue }
                let box = bounds()
                func meanX(_ net: String) -> Double {
                    let xs = placed.flatMap { q in q.posts.enumerated().filter { q.connections[$0.offset] == net }.map { Double($0.element.x) } }
                    return xs.isEmpty ? Double(box.minX) : xs.reduce(0, +) / Double(xs.count)
                }
                let x0 = meanX(n0)
                let x1 = meanX(n1)
                let cx = Int(((x0 + x1) / 2).rounded())
                let top = p.role == .bridge
                let y = top ? box.minY - 2 : box.maxY + 3
                putTwo(p, first: x0 <= x1 ? 0 : 1, GridPoint(cx - 2, y), GridPoint(cx + 2, y), step: top ? GridPoint(0, -1) : GridPoint(0, 1))
            }
            // anything else: supply decoupling and unconnected parts, along the right
            for p in parts where p.a == nil {
                if p.role == .railShunt, let first = p.connections.first(where: { cls($0.value) == .rail })?.key, p.kind.terminalNames.count == 2 {
                    putTwo(p, first: first, GridPoint(x, 0), GridPoint(x, 4))
                    x += 3
                } else {
                    put(p, GridPoint(x, 0), GridPoint(x, 0) + p.kind.defaultOffset)
                    x += 6
                }
            }
        }

        private func bounds() -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
            var points: [GridPoint] = []
            for q in placed {
                let element = q.element
                points += element.posts + [element.a, element.b] + Array(keepout(element))
            }
            guard !points.isEmpty else { return (0, 0, 0, 0) }
            return (points.map(\.x).min()!, points.map(\.y).min()!, points.map(\.x).max()!, points.map(\.y).max()!)
        }

        // MARK: Routing

        private var pinOwner: [GridPoint: Occupant] = [:]
        private var blocked = Set<GridPoint>()
        private var wires: [GridPoint: (net: String, orientation: Orientation)] = [:]
        private var pinDirection: [GridPoint: GridPoint] = [:]
        private var pinsOf: [String: [GridPoint]] = [:]
        private var netOrder: [String] = []
        private var segments: [String: Set<Edge>] = [:]

        struct Edge: Hashable {
            let a: GridPoint
            let b: GridPoint
            init(_ p: GridPoint, _ q: GridPoint) {
                if (p.x, p.y) < (q.x, q.y) { a = p; b = q } else { a = q; b = p }
            }
        }

        private func outward(_ p: Part, _ point: GridPoint) -> GridPoint {
            let element = p.element
            let posts = element.posts
            if amplifiers.contains(p.kind), posts.prefix(2).contains(point) {
                return element.axisDirection * -1
            }
            if p.kind == .timer555 {
                let perpendicular = element.perpendicular
                let relative = point - element.a
                let side = relative.x * perpendicular.x + relative.y * perpendicular.y
                return side > 0 ? perpendicular : perpendicular * -1
            }
            let all = posts + [element.a, element.b]
            let cx = Double(all.map(\.x).reduce(0, +)) / Double(all.count)
            let cy = Double(all.map(\.y).reduce(0, +)) / Double(all.count)
            let dx = Double(point.x) - cx
            let dy = Double(point.y) - cy
            return abs(dx) >= abs(dy) ? GridPoint(dx >= 0 ? 1 : -1, 0) : GridPoint(0, dy >= 0 ? 1 : -1)
        }

        private func mark(_ point: GridPoint, _ net: String, _ orientation: Orientation) {
            if let existing = wires[point], existing.net == net, existing.orientation != orientation {
                wires[point] = (net, .vertex)
            } else {
                wires[point] = (net, orientation)
            }
        }

        private func stub(_ from: GridPoint, _ to: GridPoint, _ net: String) {
            extra.append(Element(kind: .wire, a: from, b: to))
            mark(from, net, .vertex)
            mark(to, net, .vertex)
        }

        private func blockFlag(at point: GridPoint, _ direction: GridPoint, _ name: String) {
            for k in 1...(2 + name.count / 2) { blocked.insert(point + direction * k) }
        }

        func route() {
            for p in placed {
                for (i, point) in p.posts.enumerated() {
                    pinOwner[point] = p.connections[i].map { .net($0) } ?? .other
                    pinDirection[point] = outward(p, point)
                    if let net = p.connections[i] {
                        if pinsOf[net] == nil { netOrder.append(net) }
                        pinsOf[net, default: []].append(point)
                    }
                }
            }
            for p in placed {
                for point in keepout(p.element) where pinOwner[point] == nil { blocked.insert(point) }
            }
            // ground symbols and supply flags at their pins
            for net in netOrder where cls(net) != .signal {
                for point in pinsOf[net] ?? [] {
                    let d = pinDirection[point] ?? GridPoint(0, 1)
                    if cls(net) == .ground {
                        var at = point
                        var pointing = GridPoint(0, 1)
                        if d == GridPoint(0, -1) {
                            pointing = d
                        } else if d != GridPoint(0, 1) {
                            at = point + d
                            stub(point, at, net)
                        }
                        extra.append(Element(kind: .ground, a: at, b: at + pointing))
                        blocked.insert(at + pointing)
                        pinOwner[at] = .net(net)
                    } else {
                        let want = isNegativeRail(net) ? GridPoint(0, 1) : GridPoint(0, -1)
                        var at = point
                        var pointing = d
                        if d.y == 0 {
                            at = point + d
                            stub(point, at, net)
                        } else if d == want {
                            pointing = want
                        }
                        extra.append(Element(kind: .netLabel, name: net, a: at, b: at + pointing))
                        blockFlag(at: at, pointing, net)
                        pinOwner[at] = .net(net)
                    }
                }
            }
            // a net with a single pin (an output nothing else uses) gets a label with its name
            for net in netOrder where cls(net) == .signal && (pinsOf[net]?.count ?? 0) == 1 {
                guard let point = pinsOf[net]?.first else { continue }
                let d = pinDirection[point] ?? GridPoint(1, 0)
                let at = point + d
                guard pinOwner[at] == nil, !blocked.contains(at) else { continue }
                stub(point, at, net)
                extra.append(Element(kind: .netLabel, name: net, a: at, b: at + d))
                blockFlag(at: at, d, net)
                pinOwner[at] = .net(net)
            }
            // signal nets, short ones first
            func span(_ net: String) -> Int {
                let points = pinsOf[net] ?? []
                guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
                return maxX - minX + maxY - minY
            }
            let signalNets = netOrder.filter { cls($0) == .signal && Set(pinsOf[$0] ?? []).count >= 2 }
                .sorted { (span($0), pinsOf[$0]?.count ?? 0) < (span($1), pinsOf[$1]?.count ?? 0) }
            let all = Array(pinOwner.keys) + Array(blocked)
            let box = (minX: (all.map(\.x).min() ?? 0) - 4, minY: (all.map(\.y).min() ?? 0) - 4,
                       maxX: (all.map(\.x).max() ?? 0) + 4, maxY: (all.map(\.y).max() ?? 0) + 4)
            for net in signalNets {
                let points = Array(Set(pinsOf[net] ?? [])).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
                guard let first = points.first else { continue }
                var tree: Set<GridPoint> = [first]
                mark(first, net, .vertex)
                var remaining = Array(points.dropFirst())
                var paths: [[GridPoint]] = []
                var ok = true
                while !remaining.isEmpty {
                    remaining.sort { distance($0, to: tree) < distance($1, to: tree) }
                    let source = remaining.removeFirst()
                    guard let path = search(from: source, to: tree, net: net, box: box) else {
                        ok = false
                        break
                    }
                    for (i, point) in path.enumerated() {
                        if i == 0 || i == path.count - 1 {
                            mark(point, net, .vertex)
                            continue
                        }
                        let previous = path[i - 1]
                        let next = path[i + 1]
                        if previous.x == next.x {
                            mark(point, net, .vertical)
                        } else if previous.y == next.y {
                            mark(point, net, .horizontal)
                        } else {
                            mark(point, net, .vertex)
                        }
                    }
                    paths.append(path)
                    tree.formUnion(path)
                }
                if ok {
                    for path in paths {
                        for i in 0..<(path.count - 1) { segments[net, default: []].insert(Edge(path[i], path[i + 1])) }
                    }
                } else {
                    // fall back to labels at every pin of this net: always connected, if less pretty
                    for path in paths { for point in path where wires[point]?.net == net { wires[point] = nil } }
                    for point in Set(pinsOf[net] ?? []) {
                        wires[point] = (net, .vertex)
                        let d = pinDirection[point] ?? GridPoint(1, 0)
                        extra.append(Element(kind: .netLabel, name: net, a: point, b: point + d))
                    }
                }
            }
        }

        private func distance(_ p: GridPoint, to set: Set<GridPoint>) -> Int {
            set.map { abs($0.x - p.x) + abs($0.y - p.y) }.min() ?? 0
        }

        private static let directions = [GridPoint(1, 0), GridPoint(-1, 0), GridPoint(0, 1), GridPoint(0, -1)]

        /// A* from `source` to any point of `targets`, on the grid, with costs for bends, crossings and closeness
        private func search(from source: GridPoint, to targets: Set<GridPoint>, net: String,
                            box: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> [GridPoint]? {
            func estimate(_ p: GridPoint) -> Double { Double(distance(p, to: targets)) }
            let start = RouteState(point: source, direction: 4)
            var best: [RouteState: Double] = [start: 0]
            var previous: [RouteState: RouteState] = [:]
            var heap = Heap()
            heap.push(estimate(source), 0, start)
            var expansions = 0
            while let (_, cost, state) = heap.pop() {
                if let known = best[state], known < cost { continue }
                let p = state.point
                if targets.contains(p) && p != source {
                    var path = [p]
                    var s = state
                    while let before = previous[s] {
                        s = before
                        path.append(s.point)
                    }
                    return path.reversed()
                }
                expansions += 1
                if expansions > 150_000 { return nil }
                let crossing = wires[p].map { $0.net != net } ?? false
                for (index, d) in Self.directions.enumerated() {
                    if crossing && index != state.direction { continue }
                    if state.direction < 4 {
                        let back = Self.directions[state.direction] * -1
                        if d == back { continue }
                    }
                    let q = p + d
                    guard q.x >= box.minX, q.x <= box.maxX, q.y >= box.minY, q.y <= box.maxY else { continue }
                    var step = 1.0
                    if !targets.contains(q) {
                        if blocked.contains(q) || pinOwner[q] != nil { continue }
                        if let wire = wires[q], wire.net != net {
                            if wire.orientation == .vertex { continue }
                            let horizontal = d.y == 0
                            if (wire.orientation == .horizontal) == horizontal { continue }
                            step += 8
                        }
                        for around in Self.directions {
                            let r = q + around
                            if blocked.contains(r) { step += 0.3 }
                            if let wire = wires[r], wire.net != net { step += 0.4 }
                        }
                    }
                    if state.direction == 4 {
                        if let out = pinDirection[p], d != out { step += d == out * -1 ? 3 : 1.5 }
                    } else if index != state.direction {
                        step += 2.5
                    }
                    let next = RouteState(point: q, direction: index)
                    let total = cost + step
                    if total < best[next] ?? .infinity {
                        best[next] = total
                        previous[next] = state
                        heap.push(total + estimate(q), total, next)
                    }
                }
            }
            return nil
        }

        // MARK: Output

        func circuit() -> Circuit {
            var circuit = Circuit()
            for p in placed { circuit.elements.append(p.element) }
            // wires: straight runs, split where they bend, branch or meet a pin
            for net in netOrder {
                guard let edges = segments[net], !edges.isEmpty else { continue }
                var adjacent: [GridPoint: [GridPoint]] = [:]
                for edge in edges {
                    adjacent[edge.a, default: []].append(edge.b)
                    adjacent[edge.b, default: []].append(edge.a)
                }
                func isVertex(_ p: GridPoint) -> Bool {
                    guard let neighbours = adjacent[p], neighbours.count == 2, pinOwner[p] == nil else { return true }
                    return !(neighbours[0].x == neighbours[1].x || neighbours[0].y == neighbours[1].y)
                }
                var seen = Set<Edge>()
                for start in adjacent.keys.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) where isVertex(start) {
                    for next in adjacent[start] ?? [] where !seen.contains(Edge(start, next)) {
                        var run = [start, next]
                        seen.insert(Edge(start, next))
                        while !isVertex(run[run.count - 1]) {
                            let last = run[run.count - 1]
                            guard let after = adjacent[last]?.first(where: { $0 != run[run.count - 2] }) else { break }
                            seen.insert(Edge(last, after))
                            run.append(after)
                        }
                        circuit.elements.append(Element(kind: .wire, a: run[0], b: run[run.count - 1]))
                    }
                }
            }
            circuit.elements += extra
            // remember which net each terminal is on, so later changes can refer to nets by name
            for p in placed where !p.name.isEmpty {
                for (i, net) in p.connections { circuit.netNames["\(p.name).\(p.kind.terminalNames[i])"] = net }
            }
            return circuit
        }
    }

    /// A small binary min-heap for the router
    private struct Heap {
        private var items: [(priority: Double, cost: Double, state: RouteState)] = []

        mutating func push(_ priority: Double, _ cost: Double, _ state: RouteState) {
            items.append((priority, cost, state))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].priority < items[parent].priority else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> (Double, Double, RouteState)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let left = 2 * i + 1
                let right = left + 1
                var smallest = i
                if left < items.count && items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count && items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != i else { break }
                items.swapAt(i, smallest)
                i = smallest
            }
            return (top.priority, top.cost, top.state)
        }
    }
}
