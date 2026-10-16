import Foundation
import KiCadKit
import SwiftProtobuf

/// A board open in KiCad's PCB editor, changed where it stands through KiCad's API: what the schematic's update does to
/// the board (footprints removed, references, values, fields and links changed, pads put on other nets, zones and
/// vias following a renamed net) made in the editor as one change, which its Undo takes back whole; the editor then
/// gives the tracks the nets of the pads they reach, as it does on any change. Footprints new to the board are made
/// whole from their libraries' definitions (KiCadFootprintMessage), and footprints exchanged for others (or moved,
/// turned or turned over here) made again in their place under their own ids; tracks and vias routed here are made, changed and taken away as they were
/// (KiCadTrackMessage). Should KiCad refuse one, the board is written to its file with the changes and the editor
/// reads it again.
public final class KiCadLiveBoard {
    public let api: KiCadAPI
    public let document: Kiapi_Common_Types_DocumentSpecifier
    public let file: URL

    public init(api: KiCadAPI, document: Kiapi_Common_Types_DocumentSpecifier, file: URL) {
        self.api = api
        self.document = document
        self.file = file
    }

    /// The board `file` open in a running KiCad's PCB editor, if one has it open (and its API on)
    public static func find(file: URL, clientName: String? = nil) -> KiCadLiveBoard? {
        for socket in KiCadAPI.sockets() {
            guard let api = try? clientName.map({ try KiCadAPI(socket: socket, clientName: $0) }) ?? KiCadAPI(socket: socket),
                  let document = try? api.board(file: file) else { continue }
            return KiCadLiveBoard(api: api, document: document, file: file)
        }
        return nil
    }

    /// Whether the editor still has the board open
    public var isOpen: Bool { (try? api.board(file: file)) != nil }

    /// The board as the editor has it, unsaved changes and all (its footprints without the version stamps the API's
    /// text gives each one, which a board's file does not)
    public func snapshot() throws -> KiCadBoard {
        let board = try KiCadBoard(text: api.text(of: document))
        for footprint in board.root.all("footprint") {
            for head in ["version", "generator", "generator_version"] { footprint.remove(head) }
        }
        return board
    }

    /// Why the last change went to the editor by the board's file rather than item by item
    public private(set) var reloadReason: String?

    public enum Applied: Sendable, Equatable {
        /// Nothing to change
        case nothing
        /// Changed in the editor, as one change of `count` items
        case live(count: Int)
        /// Written to the file and read again by the editor
        case reloaded
    }

    /// Makes the editor's board what `after` is, `before` being the snapshot the changes were made on
    @discardableResult
    public func apply(from before: KiCadBoard, to after: KiCadBoard, message: String) throws -> Applied {
        let old = Dictionary(before.footprints.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.footprints.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        // new, or exchanged for another footprint (or turned over, moved or turned): made whole
        func placedElsewhere(_ o: KiCadFootprint, _ f: KiCadFootprint) -> Bool {
            o.libID != f.libID || o.layer != f.layer || o.position != f.position || o.rotation != f.rotation
        }
        let made = after.footprints.filter { f in old[f.uuid].map { placedElsewhere($0, f) } ?? true }
        let changed = after.footprints.filter { f in
            guard let o = old[f.uuid], !placedElsewhere(o, f) else { return false }
            return o.node.compact != f.node.compact
        }
        // stitching vias and zones whose nets the update renamed (tracks follow their pads in the editor itself)
        let oldVias = Dictionary(before.vias.map { ($0.uuid, $0.net) }, uniquingKeysWith: { a, _ in a })
        let oldZones = Dictionary(before.zones.map { ($0.uuid, $0.net) }, uniquingKeysWith: { a, _ in a })
        let vias = after.vias.filter { v in oldVias[v.uuid].map { $0 != v.net } ?? false }
        let zones = after.zones.filter { z in oldZones[z.uuid].map { $0 != z.net } ?? false }
        // tracks and vias made, changed or taken away (routed here); a track's net alone changed is the editor's to
        // follow, and a via's is above
        let oldCopper = Self.copper(before), newCopper = Self.copper(after)
        let copperRemoved = oldCopper.keys.filter { newCopper[$0] == nil }.sorted()
        let copperMade = Self.copperItems(after).filter { oldCopper[$0.value("uuid") ?? ""] == nil }
        let copperChanged = Self.copperItems(after).filter { node in
            guard let old = oldCopper[node.value("uuid") ?? ""] else { return false }
            return Self.withoutNet(old) != Self.withoutNet(node)
        }
        let count = removed.count + made.count + changed.count + vias.count + zones.count
            + copperRemoved.count + copperMade.count + copperChanged.count
        // zones made, taken away or redrawn here (a pour), or the board's outline: the board by its file (a zone's
        // settings are many, and KiCad fills it as it reads it)
        func drawn(_ zone: KiCadZone) -> String {
            let z = zone.node.copy()
            for head in ["filled_polygon", "net", "net_name"] { z.remove(head) }
            return z.compact
        }
        let oldDrawn = Dictionary(before.zones.map { ($0.uuid, drawn($0)) }, uniquingKeysWith: { a, _ in a })
        let newDrawn = Dictionary(after.zones.map { ($0.uuid, drawn($0)) }, uniquingKeysWith: { a, _ in a })
        let zonesRedrawn = Set(oldDrawn.keys) != Set(newDrawn.keys) || oldDrawn.contains { uuid, text in newDrawn[uuid].map { $0 != text } ?? false }
        if zonesRedrawn || before.edgeDrawings.map(\.compact) != after.edgeDrawings.map(\.compact) {
            reloadReason = zonesRedrawn ? "zones added, taken away or redrawn" : "the board's outline changed"
            return try reload(after)
        }
        guard count > 0 else { return .nothing }

        // the footprints, tracks and vias to make, as KiCad's API takes them; any KiCad cannot take sends the whole
        // board by its file
        var making: [(uuid: String, message: Google_Protobuf_Any)] = []
        var copperMaking: [Google_Protobuf_Any] = [], copperChanging: [Google_Protobuf_Any] = []
        do {
            for footprint in made { making.append((footprint.uuid, try Google_Protobuf_Any(message: KiCadFootprintMessage.instance(footprint)))) }
            copperMaking = try copperMade.map { try KiCadTrackMessage.message($0, board: after) }
            copperChanging = try copperChanged.map { try KiCadTrackMessage.message($0, board: after) }
        } catch {
            reloadReason = "\(error)"
            return try reload(after)
        }
        do {
            try api.commit(document, message: message) {
                try api.delete(removed + copperRemoved, in: document)
                if !copperMaking.isEmpty { try api.create(copperMaking, in: document) }
                if !copperChanging.isEmpty { try api.update(copperChanging, in: document) }
                // a new footprint made; one exchanged (or turned over) made again in its place, under its own id, as
                // KiCad's own exchange keeps it (KiCad takes a footprint's whole definition in an update: its pads,
                // drawings and models made anew)
                let created = making.filter { old[$0.uuid] == nil }.map(\.message)
                let exchanged = making.filter { old[$0.uuid] != nil }.map(\.message)
                if !created.isEmpty { try api.create(created, in: document) }
                if !exchanged.isEmpty { try api.update(exchanged, in: document) }
                if !changed.isEmpty {
                    let current = try api.items(changed.map(\.uuid), in: document)
                    var updates: [Google_Protobuf_Any] = []
                    for item in current {
                        var instance = try Kiapi_Board_Types_FootprintInstance(unpackingAny: item)
                        guard let ours = new[instance.id.value] else { continue }
                        try Self.patch(&instance, from: ours)
                        updates.append(try Google_Protobuf_Any(message: instance))
                    }
                    try api.update(updates, in: document)
                }
                if !vias.isEmpty || !zones.isEmpty {
                    let nets = Dictionary((vias.map { ($0.uuid, $0.net) } + zones.map { ($0.uuid, $0.net) }), uniquingKeysWith: { a, _ in a })
                    var updates: [Google_Protobuf_Any] = []
                    for item in try api.items(Array(nets.keys), in: document) {
                        if var via = try? Kiapi_Board_Types_Via(unpackingAny: item) {
                            via.net.name = (nets[via.id.value] ?? nil) ?? ""
                            updates.append(try Google_Protobuf_Any(message: via))
                        } else if var zone = try? Kiapi_Board_Types_Zone(unpackingAny: item) {
                            zone.copperSettings.net.name = (nets[zone.id.value] ?? nil) ?? ""
                            updates.append(try Google_Protobuf_Any(message: zone))
                        }
                    }
                    try api.update(updates, in: document)
                }
            }
        } catch let failure as KiCadAPI.Failure where !failure.isTransient {
            // KiCad would not take the change item by item: the board by its file
            if case .notListening = failure { throw failure }
            reloadReason = failure.description
            return try reload(after)
        }
        return .live(count: count)
    }

    /// A board's tracks, arc tracks and vias, in its order
    static func copperItems(_ board: KiCadBoard) -> [SExpr] {
        board.root.items.filter { ["segment", "arc", "via"].contains($0.head ?? "") && $0.value("uuid") != nil }
    }

    /// A board's tracks, arc tracks and vias by id
    static func copper(_ board: KiCadBoard) -> [String: SExpr] {
        Dictionary(copperItems(board).map { ($0.value("uuid") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A track or via without its net, to compare the rest
    static func withoutNet(_ node: SExpr) -> String {
        let n = node.copy()
        n.remove("net")
        return n.compact
    }

    /// Writes `board` to the file and has the editor read it again
    func reload(_ board: KiCadBoard) throws -> Applied {
        try board.write(to: file)
        try api.revert(document)
        return .reloaded
    }

    /// Makes a footprint as KiCad has it what ours is: its reference, value and fields, its fabrication flags, its link
    /// to the schematic, and its pads' nets and pins
    static func patch(_ instance: inout Kiapi_Board_Types_FootprintInstance, from footprint: KiCadFootprint) throws {
        instance.referenceField.text.text.text = footprint.reference
        instance.valueField.text.text.text = footprint.value
        if let datasheet = footprint.property("Datasheet") { instance.datasheetField.text.text.text = datasheet }
        if let description = footprint.property("Description") { instance.descriptionField.text.text.text = description }
        let attributes = footprint.attributes
        instance.attributes.doNotPopulate = attributes.contains("dnp")
        instance.attributes.excludeFromBillOfMaterials = attributes.contains("exclude_from_bom")
        instance.attributes.excludeFromPositionFiles = attributes.contains("exclude_from_pos_files")
        instance.symbolPath = KiCadFootprintMessage.sheetPath(footprint.path)

        let mandatory: Set<String> = ["Reference", "Value", "Datasheet", "Description", "Footprint"]
        var fields: [String: String] = [:]
        for p in footprint.properties where !mandatory.contains(p.name) { fields[p.name] = p.value }
        let pads = footprint.pads
        var items: [Google_Protobuf_Any] = []
        for item in instance.definition.items {
            if item.isA(Kiapi_Board_Types_Field.self) {
                var field = try Kiapi_Board_Types_Field(unpackingAny: item)
                if let value = fields.removeValue(forKey: field.name) { field.text.text.text = value }
                items.append(try Google_Protobuf_Any(message: field))
            } else if item.isA(Kiapi_Board_Types_Pad.self) {
                var pad = try Kiapi_Board_Types_Pad(unpackingAny: item)
                if let ours = pads.first(where: { $0.uuid == pad.id.value }) ?? pads.first(where: { $0.number == pad.number }) {
                    pad.net.name = ours.net ?? ""
                    pad.symbolPin = KiCadFootprintMessage.pin(ours)
                }
                items.append(try Google_Protobuf_Any(message: pad))
            } else {
                items.append(item)
            }
        }
        // fields the footprint did not have: hidden, on the fabrication layer, where the footprint is
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            var field = Kiapi_Board_Types_Field()
            field.name = name
            field.text.text.text = value
            field.text.text.position = instance.position
            field.text.layer = footprint.isOnBack ? .blBFab : .blFFab
            field.visible = false
            items.append(try Google_Protobuf_Any(message: field))
        }
        instance.definition.items = items
    }
}
