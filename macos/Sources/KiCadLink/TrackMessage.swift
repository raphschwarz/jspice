import Foundation
import KiCadKit
import SwiftProtobuf

/// A track, arc track or via of a board file as KiCad's API carries one (kiapi.board.types.Track, Arc, Via), as
/// KiCad's PCB_TRACK, PCB_ARC and PCB_VIA read them back (Deserialize, pcbnew/pcb_track.cpp): positions and sizes in
/// nanometres, a via's size and drill in its padstack (one copper shape for all its layers, its drill from its first
/// layer to its last).
public enum KiCadTrackMessage {
    /// The track or via, ready for the API's create or update
    public static func message(_ node: SExpr, board: KiCadBoard) throws -> Google_Protobuf_Any {
        switch node.head {
        case "segment": return try Google_Protobuf_Any(message: track(node, board: board))
        case "arc": return try Google_Protobuf_Any(message: arc(node, board: board))
        case "via": return try Google_Protobuf_Any(message: via(node, board: board))
        default: throw KiCadFootprintMessage.Unsupported(description: "a board item \(node.head ?? "")")
        }
    }

    static func point(_ list: SExpr?) -> Kiapi_Common_Types_Vector2 {
        KiCadFootprintMessage.vector(KiCadPoint(list?.number(at: 0) ?? 0, list?.number(at: 1) ?? 0))
    }

    static func net(_ node: SExpr, board: KiCadBoard) -> Kiapi_Board_Types_Net {
        var net = Kiapi_Board_Types_Net()
        net.name = board.netName(node["net"]) ?? ""
        return net
    }

    static func locked(_ node: SExpr) -> Kiapi_Common_Types_LockedState {
        node.flag("locked") || node.value("locked") == "yes" ? .lsLocked : .lsUnlocked
    }

    public static func track(_ node: SExpr, board: KiCadBoard) throws -> Kiapi_Board_Types_Track {
        var t = Kiapi_Board_Types_Track()
        t.id.value = node.value("uuid") ?? ""
        t.start = point(node["start"])
        t.end = point(node["end"])
        t.width = KiCadFootprintMessage.distance(node["width"]?.number(at: 0) ?? 0.25)
        t.layer = try KiCadFootprintMessage.layer(node.value("layer") ?? "F.Cu")
        t.net = net(node, board: board)
        t.locked = locked(node)
        return t
    }

    public static func arc(_ node: SExpr, board: KiCadBoard) throws -> Kiapi_Board_Types_Arc {
        var a = Kiapi_Board_Types_Arc()
        a.id.value = node.value("uuid") ?? ""
        a.start = point(node["start"])
        a.mid = point(node["mid"])
        a.end = point(node["end"])
        a.width = KiCadFootprintMessage.distance(node["width"]?.number(at: 0) ?? 0.25)
        a.layer = try KiCadFootprintMessage.layer(node.value("layer") ?? "F.Cu")
        a.net = net(node, board: board)
        a.locked = locked(node)
        return a
    }

    public static func via(_ node: SExpr, board: KiCadBoard) throws -> Kiapi_Board_Types_Via {
        var v = Kiapi_Board_Types_Via()
        v.id.value = node.value("uuid") ?? ""
        v.position = point(node["at"])
        let size = node["size"]?.number(at: 0) ?? 0.6
        let drill = node["drill"]?.number(at: 0) ?? 0.3
        let names = node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]
        let first = try KiCadFootprintMessage.layer(names.first ?? "F.Cu")
        let last = try KiCadFootprintMessage.layer(names.last ?? "B.Cu")

        var stack = Kiapi_Board_Types_PadStack()
        stack.type = .pstNormal
        stack.layers = [first, last]
        var d = Kiapi_Board_Types_DrillProperties()
        d.diameter = KiCadFootprintMessage.vector(KiCadPoint(drill, drill))
        d.shape = .dsCircle
        d.startLayer = first
        d.endLayer = last
        stack.drill = d
        stack.unconnectedLayerRemoval = node.value("remove_unused_layers") == "yes" || node.flag("remove_unused_layers")
            ? (node.value("keep_end_layers") == "yes" || node.flag("keep_end_layers") ? .ulrRemoveExceptStartAndEnd : .ulrRemove)
            : .ulrKeep
        var copper = Kiapi_Board_Types_PadStackLayer()
        copper.layer = .blFCu
        copper.shape = .pssCircle
        copper.size = KiCadFootprintMessage.vector(KiCadPoint(size, size))
        stack.copperLayers = [copper]
        v.padStack = stack

        switch node.text(at: 0) {
        case "blind", "buried": v.type = .vtBlindBuried
        case "micro": v.type = .vtMicro
        default: v.type = first == .blFCu && last == .blBCu ? .vtThrough : .vtBlindBuried
        }
        v.net = net(node, board: board)
        v.locked = locked(node)
        if node.value("free") == "yes" || node.flag("free") { v.isFree = true }
        return v
    }
}
