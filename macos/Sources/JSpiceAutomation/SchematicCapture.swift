import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vision
import CircuitKit

/// Reads a schematic drawing (a photo, a scan, a PDF) into a circuit.
///
/// The page is rendered to an image, and its text labels are found with their positions: from the PDF itself when it
/// has text, by on-device text recognition otherwise. Claude reads the drawing with those labels as hints and writes
/// a netlist in the form `build_circuit` takes (each part's kind, value, model and the nets of its terminals); JSpice
/// checks it by building the circuit, and gives any error back for one more look. The result is drawn as a tidy
/// schematic and comes with the model's notes on anything it was unsure of.
public enum SchematicCapture {
    /// A page ready to send: the image, and the text found on it
    public struct Page {
        public var image: Data
        public var mediaType: String
        public var labels: [Label]
        /// Pixel size of the image sent
        public var size: CGSize
        /// What else to know (a PDF with more pages than the one read)
        public var notes: [String] = []
    }

    /// A text label on the page, its box from 0 to 1 with the origin at the top left
    public struct Label: Equatable {
        public var text: String
        public var box: CGRect
    }

    public struct Capture {
        public var circuit: Circuit
        public var title: String
        /// The model's notes: values it could not read, parts it had to guess, what it left out
        public var notes: [String]
        /// Parts the model marked as uncertain, with what it saw
        public var uncertain: [String]
        /// Model turns taken (more than one when the first netlist did not build)
        public var attempts: Int
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case unreadable(String)
        case noKey
        case api(String)
        case refused(String)
        case unusable(String)

        public var description: String {
            switch self {
            case .unreadable(let why): return "The file can't be read as a schematic: \(why)"
            case .noKey: return "An Anthropic API key is needed to read schematics (set ANTHROPIC_API_KEY, or enter one in JSpice)"
            case .api(let message): return "The Claude API returned an error: \(message)"
            case .refused(let why): return "Claude declined to read this drawing\(why.isEmpty ? "" : ": " + why)"
            case .unusable(let why): return "The drawing could not be turned into a circuit: \(why)"
            }
        }
    }

    public static let model = "claude-opus-5-5"
    /// The longest side of the image sent, in pixels
    static let maximumSide = 2048
    /// Netlists that do not build are sent back this many times
    static let repairs = 2

    // MARK: - Reading the page

    /// The first page of a PDF, or an image file, rendered and labelled
    public static func page(from url: URL) throws -> Page {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url), document.pageCount > 0, let page = document.page(at: 0) else {
                throw CaptureError.unreadable("not a PDF with pages")
            }
            var result = try render(page)
            if document.pageCount > 1 {
                result.notes.append("The PDF has \(document.pageCount) pages; the first was read")
            }
            return result
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            throw CaptureError.unreadable("not an image")
        }
        return try Self.page(from: image, labels: recognizeText(in: image))
    }

    /// A PDF page drawn on white, its text taken from the PDF (or recognised, for a scanned page)
    static func render(_ page: PDFPage) throws -> Page {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { throw CaptureError.unreadable("the page is empty") }
        let scale = CGFloat(maximumSide) / max(bounds.width, bounds.height)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.unreadable("the page can't be drawn")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        if let ref = page.pageRef { context.drawPDFPage(ref) }
        guard let image = context.makeImage() else { throw CaptureError.unreadable("the page can't be drawn") }
        var labels = textLabels(page)
        if labels.isEmpty { labels = recognizeText(in: image) }
        return try self.page(from: image, labels: labels)
    }

    static func page(from image: CGImage, labels: [Label]) throws -> Page {
        // PNG keeps thin lines and small print sharp; a photo too big for it goes as JPEG
        for (type, mediaType, options) in [(UTType.png, "image/png", [:] as [CFString: Any]),
                                           (UTType.jpeg, "image/jpeg", [kCGImageDestinationLossyCompressionQuality: 0.85] as [CFString: Any])] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if data.length < 4_500_000 {
                return Page(image: data as Data, mediaType: mediaType, labels: labels,
                            size: CGSize(width: image.width, height: image.height))
            }
        }
        throw CaptureError.unreadable("the image is too large to send")
    }

    /// The text of a PDF page, line by line with its place
    static func textLabels(_ page: PDFPage) -> [Label] {
        let bounds = page.bounds(for: .mediaBox)
        guard let all = page.selection(for: bounds) else { return [] }
        return all.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let box = line.bounds(for: page)
            // PDF space has its origin at the bottom left
            return Label(text: text, box: CGRect(x: (box.minX - bounds.minX) / bounds.width,
                                                 y: (bounds.maxY - box.maxY) / bounds.height,
                                                 width: box.width / bounds.width, height: box.height / bounds.height))
        }
    }

    /// The text in an image, read on this Mac (part names and values: "R1", "4k7", "100n", "TL072")
    static func recognizeText(in image: CGImage) -> [Label] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // part values are not words: "4k7" must not become "4K7" or "ak7"
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Label(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

    // MARK: - The request

    /// What JSpice can build: each kind's terminals, parameters and models, for the model to choose from
    static var catalog: String {
        ElementKind.allCases.filter { ![.block, .port, .probe, .wire].contains($0) }.map { kind in
            var line = "\(kind.rawValue) (\(kind.displayName)): terminals \(kind.terminalNames.joined(separator: ", "))"
            // (a model card's other parameters left out: a drawing gives a part's name, not its card)
            let params = kind.params.filter { !$0.advanced }.map { spec in spec.unit.isEmpty ? spec.key : "\(spec.key) [\(spec.unit)]" }
            if !params.isEmpty { line += "; params \(params.joined(separator: ", "))" }
            let models = kind.models.map(\.name)
            if !models.isEmpty { line += "; models \(models.joined(separator: ", "))" }
            return line
        }.joined(separator: "\n")
    }

    static var instructions: String {
        """
        You transcribe electronic schematic drawings into netlists for JSpice, a circuit simulator. Read the drawing \
        carefully: follow every wire, note every junction dot (wires that cross without a dot are not connected), and \
        treat net labels, power flags and ground symbols with the same name as one net.

        Write one entry per part, using only the kinds, terminal names and parameter keys below. Name parts as the \
        drawing does (R1, C3, Q2, U1A). Give values as written ("4k7", "100n", "2.2u", "1M" for one megohm) in the \
        parameter that kind uses for its value (resistance, capacitance, inductance, voltage…). Choose a model only from \
        the list for that kind, and only when the drawing names that part or an equivalent; otherwise leave it empty. \
        A dual op-amp drawn as two halves is two opAmp parts. Name nets after the drawing's labels where it has them \
        ("VCC", "OUT"); call ground "GND"; invent short names for the rest ("n1", "base_q1"). A supply drawn as a flag \
        (+9V) becomes a dcVoltage part from that net to GND. Connect every terminal of every part.

        If something can't be read or doesn't map onto these kinds, choose the closest and say so in that part's \
        reading, set its confidence to low, and add a note. Never invent parts that aren't drawn.

        Text found on the page, with its place (x, y from the top left, as fractions of the page), is given with the \
        drawing; use it to read values exactly, but trust the drawing for what connects to what.

        Parts JSpice can build:
        \(catalog)
        """
    }

    /// The netlist the model writes: a strict JSON schema, every object closed and every field required
    static var outputSchema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let kinds = ElementKind.allCases.filter { ![.block, .port, .probe, .wire].contains($0) }.map(\.rawValue)
        let part = object([
            "kind": ["type": "string", "enum": kinds],
            "name": ["type": "string"],
            "model": ["type": "string", "description": "A model name from the list for this kind, or empty"],
            "params": ["type": "array", "items": object(["key": ["type": "string"], "value": ["type": "string"]])],
            "connections": ["type": "array", "items": object(["terminal": ["type": "string"], "net": ["type": "string"]])],
            "reading": ["type": "string", "description": "What the drawing shows for this part: its label, value and anything unclear"],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
        ])
        return object([
            "title": ["type": "string", "description": "The circuit's name, from the drawing if it has one"],
            "parts": ["type": "array", "items": part],
            "notes": ["type": "array", "items": ["type": "string"], "description": "Anything unreadable, guessed or left out"],
        ])
    }

    static func labelText(_ labels: [Label]) -> String {
        guard !labels.isEmpty else { return "No text was found on the page." }
        let lines = labels.prefix(400).map { label in
            String(format: "%@ @ (%.3f, %.3f)", label.text, label.box.midX, label.box.midY)
        }
        return "Text on the page:\n" + lines.joined(separator: "\n")
    }

    /// The first message: the drawing, then its text
    static func firstMessage(_ page: Page, extra: String?) -> [String: Any] {
        var content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": page.mediaType, "data": page.image.base64EncodedString()]],
            ["type": "text", "text": labelText(page.labels)],
            ["type": "text", "text": "Transcribe this schematic." + (extra.map { " " + $0 } ?? "")],
        ]
        if page.labels.isEmpty { content.remove(at: 1) }
        return ["role": "user", "content": content]
    }

    static func body(messages: [[String: Any]]) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 64_000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": outputSchema]],
            // a declined request is retried on the model Anthropic recommends for that kind of refusal
            "fallbacks": "default",
            "system": [["type": "text", "text": instructions, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
    }

    // MARK: - Talking to the API

    /// What a streamed reply came to: its content blocks as sent (to send back on a second turn), the text, and why
    /// it stopped
    struct Reply {
        var content: [[String: Any]] = []
        var text = ""
        var stopReason = ""
        var refusal = ""
        var error: String?
    }

    /// Folds a stream of server-sent events into the reply
    static func reply(fromEvents lines: [String]) -> Reply {
        var reply = Reply()
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        for line in lines where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_start":
                if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] { blocks[index] = block }
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { continue }
                var block = blocks[index] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + piece
                    reply.text += piece
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                blocks[index] = block
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let stop = delta["stop_reason"] as? String { reply.stopReason = stop }
                    if let details = delta["stop_details"] as? [String: Any] {
                        reply.refusal = details["explanation"] as? String ?? details["category"] as? String ?? ""
                    }
                }
            case "error":
                let error = event["error"] as? [String: Any]
                reply.error = error?["message"] as? String ?? "\(event)"
            default:
                break
            }
        }
        for (index, json) in partialJSON {
            if let data = json.data(using: .utf8), let input = try? JSONSerialization.jsonObject(with: data) { blocks[index]?["input"] = input }
        }
        reply.content = blocks.keys.sorted().compactMap { blocks[$0] }
        return reply
    }

    static func send(_ body: [String: Any], key: String, progress: @escaping @Sendable (String) -> Void) async throws -> Reply {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var lines: [String] = []
        var characters = 0
        for try await line in bytes.lines {
            lines.append(line)
            if line.contains("text_delta") {
                characters += line.count
                if lines.count % 40 == 0 { progress("Writing the netlist… (\(characters / 1000) k)") }
            } else if line.contains("thinking_delta") && lines.count % 80 == 0 {
                progress("Reading the drawing…")
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // an error before the stream started comes back as one JSON object
            let text = lines.joined(separator: "\n")
            let message = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            if [429, 500, 502, 503, 504, 529].contains(http.statusCode) {
                let wait = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                throw Busy(message: "HTTP \(http.statusCode)" + (message.map { ": " + $0 } ?? ""), wait: wait)
            }
            throw CaptureError.api("HTTP \(http.statusCode)" + (message.map { ": " + $0 } ?? ""))
        }
        let result = reply(fromEvents: lines)
        // overloaded part-way through the stream
        if let error = result.error, error.lowercased().contains("overloaded") { throw Busy(message: error, wait: nil) }
        return result
    }

    /// The API is busy or rate-limited for now: worth asking again
    struct Busy: Error {
        var message: String
        var wait: Double?
    }

    /// `send`, asked again up to three times when the API is busy, waiting longer each time (or as long as it says)
    static func sendRetrying(_ body: [String: Any], key: String, progress: @escaping @Sendable (String) -> Void) async throws -> Reply {
        var delay = 2.0
        for attempt in 1... {
            do {
                return try await send(body, key: key, progress: progress)
            } catch let busy as Busy {
                guard attempt <= 3 else { throw CaptureError.api(busy.message) }
                let wait = min(busy.wait ?? delay, 60)
                progress("Claude is busy: trying again in \(Int(wait.rounded())) s…")
                try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                delay *= 2
            }
        }
        fatalError("unreachable")
    }

    // MARK: - From netlist to circuit

    /// The model's netlist as `build_circuit` parts, leaving out models and parameters JSpice does not have (and
    /// saying so) rather than failing on them
    static func netlistParts(from netlist: [String: Any]) throws -> (parts: [[String: Any]], notes: [String]) {
        guard let entries = netlist["parts"] as? [[String: Any]], !entries.isEmpty else {
            throw CaptureError.unusable("no parts were found in the drawing")
        }
        var notes: [String] = []
        let parts = entries.map { entry -> [String: Any] in
            var part: [String: Any] = ["kind": entry["kind"] as? String ?? ""]
            let name = entry["name"] as? String ?? ""
            if !name.isEmpty { part["name"] = name }
            let kind = ElementKind(rawValue: part["kind"] as? String ?? "")
            if let model = entry["model"] as? String, !model.isEmpty {
                if let kind, kind.models.contains(where: { $0.name.lowercased() == model.lowercased() }) {
                    part["model"] = model
                } else {
                    notes.append("\(name): JSpice has no model \(model), so it behaves as a generic part")
                }
            }
            var params: [String: Any] = [:]
            for item in entry["params"] as? [[String: Any]] ?? [] {
                guard let key = item["key"] as? String, let value = item["value"] as? String, !value.isEmpty else { continue }
                if let kind, !kind.params.contains(where: { $0.key == key }) {
                    notes.append("\(name): \(key) = \(value) has no place in a \(kind.displayName.lowercased()), left out")
                    continue
                }
                params[key] = value
            }
            if !params.isEmpty { part["params"] = params }
            var connections: [String: String] = [:]
            for item in entry["connections"] as? [[String: Any]] ?? [] {
                if let terminal = item["terminal"] as? String, let net = item["net"] as? String, !net.isEmpty { connections[terminal] = net }
            }
            part["connections"] = connections
            return part
        }
        return (parts, notes)
    }

    /// What is wrong with the netlist that building it would not catch: terminals left open, nets touching one part
    static func check(_ parts: [[String: Any]]) -> [String] {
        var problems: [String] = []
        var count: [String: Int] = [:]
        for part in parts {
            let name = part["name"] as? String ?? (part["kind"] as? String ?? "?")
            let connections = part["connections"] as? [String: String] ?? [:]
            if let kind = ElementKind(rawValue: part["kind"] as? String ?? "") {
                let open = kind.terminalNames.filter { connections[$0] == nil }
                if !open.isEmpty { problems.append("\(name) has no net for \(open.joined(separator: ", "))") }
                let unknown = connections.keys.filter { !kind.terminalNames.contains($0) }.sorted()
                if !unknown.isEmpty {
                    problems.append("\(name) has no terminal \(unknown.joined(separator: ", ")) (a \(kind.rawValue) has \(kind.terminalNames.joined(separator: ", ")))")
                }
            }
            for net in Set(connections.values) { count[net, default: 0] += 1 }
        }
        let lonely = count.filter { $0.value == 1 && $0.key != "GND" }.map(\.key).sorted()
        if !lonely.isEmpty { problems.append("These nets reach only one terminal: \(lonely.joined(separator: ", "))") }
        return problems
    }

    /// Builds the circuit, or says what failed
    static func build(_ parts: [[String: Any]]) -> Swift.Result<Circuit, ToolError> {
        let session = CircuitSession()
        do {
            _ = try session.call("build_circuit", arguments: ["parts": parts])
            return .success(session.circuit)
        } catch let error as ToolError {
            return .failure(error)
        } catch {
            return .failure(ToolError("\(error)"))
        }
    }

    /// Reads the schematic in `url` into a circuit: one turn for the netlist, and up to two more when it does not
    /// build or leaves terminals open
    public static func capture(_ url: URL, key: String, hint: String? = nil,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Capture {
        guard !key.isEmpty else { throw CaptureError.noKey }
        progress("Reading the page…")
        let scanned = try Self.page(from: url)
        progress(scanned.labels.isEmpty ? "Sending the drawing to Claude…" : "Sending the drawing and \(scanned.labels.count) labels to Claude…")
        var messages: [[String: Any]] = [firstMessage(scanned, extra: hint)]
        var attempt = 0
        while true {
            attempt += 1
            let reply = try await sendRetrying(body(messages: messages), key: key, progress: progress)
            if let error = reply.error { throw CaptureError.api(error) }
            if reply.stopReason == "refusal" { throw CaptureError.refused(reply.refusal) }
            if reply.stopReason == "max_tokens" { throw CaptureError.unusable("the netlist was too long to finish") }
            guard let data = reply.text.data(using: .utf8),
                  let netlist = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CaptureError.unusable("the reply was not a netlist")
            }
            let (parts, dropped) = try netlistParts(from: netlist)
            var problems = check(parts)
            var built: Circuit?
            switch build(parts) {
            case .success(let circuit): built = circuit
            case .failure(let error): problems.insert(error.description, at: 0)
            }
            if let built, problems.isEmpty || attempt > repairs {
                let entries = netlist["parts"] as? [[String: Any]] ?? []
                let uncertain = entries.filter { ($0["confidence"] as? String) == "low" }.map {
                    "\($0["name"] as? String ?? "?"): \($0["reading"] as? String ?? "")"
                }
                return Capture(circuit: built, title: netlist["title"] as? String ?? "", notes:
                                scanned.notes + (netlist["notes"] as? [String] ?? []) + dropped + problems,
                              uncertain: uncertain, attempts: attempt)
            }
            guard attempt <= repairs else { throw CaptureError.unusable(problems.joined(separator: "; ")) }
            progress("Checking the netlist again: \(problems.first ?? "")")
            // the reply goes back as it came (thinking included), then what JSpice found
            messages.append(["role": "assistant", "content": reply.content])
            messages.append(["role": "user", "content": [["type": "text", "text": """
                JSpice could not use that netlist as it is:
                \(problems.map { "- " + $0 }.joined(separator: "\n"))
                Look at the drawing again and write the whole netlist corrected.
                """]]])
        }
    }
}
