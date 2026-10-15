import Foundation
import KiCadKit
import SwiftProtobuf

/// KiCad's API (KiCad 9 and later), as a client of a running KiCad: each request a protobuf message in KiCad's
/// envelope (ApiRequest, its header naming this client), sent over the NNG socket KiCad listens on, the reply's
/// status checked and its message unpacked. KiCad answers one request at a time; so does this client.
public final class KiCadAPI {
    public enum Failure: Error, CustomStringConvertible {
        /// No KiCad listening (not running, or its API is off: Preferences ▸ Plugins ▸ Enable KiCad API)
        case notListening(String)
        /// KiCad's answer: busy (a tool or dialog is open), not ready (starting), unhandled (no board open)…
        case status(Kiapi_Common_ApiStatusCode, String)
        case reply(String)

        public var description: String {
            switch self {
            case .notListening(let why): return "KiCad is not listening: \(why)"
            case .status(let code, let message):
                switch code {
                case .asBusy: return "KiCad is busy (a dialog or tool is open there)"
                case .asNotReady: return "KiCad is still starting"
                default: return message.isEmpty ? "KiCad answered \(code)" : message
                }
            case .reply(let why): return why
            }
        }

        /// Worth asking again in a moment
        public var isTransient: Bool {
            if case .status(let code, _) = self { return code == .asBusy || code == .asNotReady }
            return false
        }
    }

    let socket: NNGRequestSocket
    public let clientName: String
    private var token = ""
    private let lock = NSLock()

    /// The sockets KiCads are listening on: /tmp/kicad/api.sock (KiCad's place on a Mac and on Linux), and
    /// api-<pid>.sock for each further KiCad running at once; KICAD_API_SOCKET's first if it is set
    public static func sockets(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var found: [String] = []
        if let given = environment["KICAD_API_SOCKET"] { found.append(given.hasPrefix("ipc://") ? String(given.dropFirst(6)) : given) }
        var folders = ["/tmp/kicad"]
        #if os(Linux)
        if let tmp = environment["TMPDIR"] { folders.append(URL(fileURLWithPath: tmp).appendingPathComponent("kicad").path) }
        #endif
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where name.hasPrefix("api") && name.hasSuffix(".sock") {
                let path = folder + "/" + name
                if !found.contains(path) { found.append(path) }
            }
        }
        return found
    }

    public init(socket path: String, clientName: String = "org.knowm.jspice-\(ProcessInfo.processInfo.processIdentifier)",
                timeout: TimeInterval = 10) throws {
        do {
            socket = try NNGRequestSocket(path: path, timeout: timeout)
        } catch {
            throw Failure.notListening("\(error)")
        }
        self.clientName = clientName
    }

    /// Sends `request` and unpacks the reply as `R`
    public func call<R: SwiftProtobuf.Message>(_ request: some SwiftProtobuf.Message, _: R.Type = R.self) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        var envelope = Kiapi_Common_ApiRequest()
        envelope.header.kicadToken = token
        envelope.header.clientName = clientName
        envelope.message = try Google_Protobuf_Any(message: request)
        let reply: [UInt8]
        do {
            reply = try socket.request(try envelope.serializedBytes())
        } catch {
            throw Failure.notListening("\(error)")
        }
        let response = try Kiapi_Common_ApiResponse(serializedBytes: reply)
        if token.isEmpty { token = response.header.kicadToken }
        guard response.status.status == .asOk else { throw Failure.status(response.status.status, response.status.errorMessage) }
        if R.self == Google_Protobuf_Empty.self { return R() }
        guard response.hasMessage else { return R() }
        do {
            return try R(unpackingAny: response.message)
        } catch {
            throw Failure.reply("KiCad's reply was not a \(R.protoMessageName): \(response.message.typeURL)")
        }
    }

    // MARK: - KiCad and its documents

    /// "10.0.7"
    public func version() throws -> (major: Int, minor: Int, patch: Int, full: String) {
        let v = try call(Kiapi_Common_Commands_GetVersion(), Kiapi_Common_Commands_GetVersionResponse.self).version
        return (Int(v.major), Int(v.minor), Int(v.patch), v.fullVersion)
    }

    /// The boards open in KiCad's PCB editor
    public func openBoards() throws -> [Kiapi_Common_Types_DocumentSpecifier] {
        var request = Kiapi_Common_Commands_GetOpenDocuments()
        request.type = .doctypePcb
        return try call(request, Kiapi_Common_Commands_GetOpenDocumentsResponse.self).documents
    }

    /// The open board whose file is `file`, if it is open
    public func board(file: URL) throws -> Kiapi_Common_Types_DocumentSpecifier? {
        let boards = try openBoards()
        let name = file.lastPathComponent
        let folder = file.deletingLastPathComponent().standardizedFileURL.path
        return boards.first { doc in
            doc.boardFilename == name && (doc.project.path.isEmpty
                || URL(fileURLWithPath: doc.project.path).standardizedFileURL.path == folder)
        } ?? boards.first { $0.boardFilename == name }
    }

    /// The board as it stands in the editor, unsaved changes and all, as its file would have it
    public func text(of document: Kiapi_Common_Types_DocumentSpecifier) throws -> String {
        var request = Kiapi_Common_Commands_SaveDocumentToString()
        request.document = document
        return try call(request, Kiapi_Common_Commands_SavedDocumentResponse.self).contents
    }

    /// Saves the board to its file
    public func save(_ document: Kiapi_Common_Types_DocumentSpecifier) throws {
        var request = Kiapi_Common_Commands_SaveDocument()
        request.document = document
        _ = try call(request, Google_Protobuf_Empty.self)
    }

    /// Reads the board again from its file, dropping what the editor had not saved
    public func revert(_ document: Kiapi_Common_Types_DocumentSpecifier) throws {
        var request = Kiapi_Common_Commands_RevertDocument()
        request.document = document
        _ = try call(request, Google_Protobuf_Empty.self)
    }

    // MARK: - Items

    static func header(_ document: Kiapi_Common_Types_DocumentSpecifier, container: String? = nil) -> Kiapi_Common_Types_ItemHeader {
        var header = Kiapi_Common_Types_ItemHeader()
        header.document = document
        if let container { header.container.value = container }
        return header
    }

    static func kiid(_ id: String) -> Kiapi_Common_Types_KIID {
        var k = Kiapi_Common_Types_KIID()
        k.value = id
        return k
    }

    /// Every footprint on the board
    public func footprints(_ document: Kiapi_Common_Types_DocumentSpecifier) throws -> [Kiapi_Board_Types_FootprintInstance] {
        var request = Kiapi_Common_Commands_GetItems()
        request.header = Self.header(document)
        request.types = [.kotPcbFootprint]
        return try call(request, Kiapi_Common_Commands_GetItemsResponse.self).items.map {
            try Kiapi_Board_Types_FootprintInstance(unpackingAny: $0)
        }
    }

    /// Items by their ids (KiCad 10)
    public func items(_ ids: [String], in document: Kiapi_Common_Types_DocumentSpecifier) throws -> [Google_Protobuf_Any] {
        var request = Kiapi_Common_Commands_GetItemsById()
        request.header = Self.header(document)
        request.items = ids.map(Self.kiid)
        return try call(request, Kiapi_Common_Commands_GetItemsResponse.self).items
    }

    /// Replaces items with these (each replaced whole: what a message leaves out, the item loses)
    @discardableResult
    public func update(_ items: [Google_Protobuf_Any], in document: Kiapi_Common_Types_DocumentSpecifier,
                       container: String? = nil) throws -> Kiapi_Common_Commands_UpdateItemsResponse {
        var request = Kiapi_Common_Commands_UpdateItems()
        request.header = Self.header(document, container: container)
        request.items = items
        let response = try call(request, Kiapi_Common_Commands_UpdateItemsResponse.self)
        if let bad = response.updatedItems.first(where: { $0.status.code != .iscOk }) {
            throw Failure.reply("KiCad did not update an item: \(bad.status.errorMessage) (\(bad.status.code))")
        }
        return response
    }

    /// Adds items; KiCad gives their children new ids, which the reply's items have
    @discardableResult
    public func create(_ items: [Google_Protobuf_Any], in document: Kiapi_Common_Types_DocumentSpecifier,
                       container: String? = nil) throws -> Kiapi_Common_Commands_CreateItemsResponse {
        var request = Kiapi_Common_Commands_CreateItems()
        request.header = Self.header(document, container: container)
        request.items = items
        let response = try call(request, Kiapi_Common_Commands_CreateItemsResponse.self)
        if let bad = response.createdItems.first(where: { $0.status.code != .iscOk }) {
            throw Failure.reply("KiCad did not create an item: \(bad.status.errorMessage) (\(bad.status.code))")
        }
        return response
    }

    public func delete(_ ids: [String], in document: Kiapi_Common_Types_DocumentSpecifier) throws {
        guard !ids.isEmpty else { return }
        var request = Kiapi_Common_Commands_DeleteItems()
        request.header = Self.header(document)
        request.itemIds = ids.map(Self.kiid)
        _ = try call(request, Kiapi_Common_Commands_DeleteItemsResponse.self)
    }

    /// Runs `changes` as one change in the editor (one step of its undo), named `message`; dropped if they fail
    public func commit<T>(_ document: Kiapi_Common_Types_DocumentSpecifier, message: String, _ changes: () throws -> T) throws -> T {
        var begin = Kiapi_Common_Commands_BeginCommit()
        begin.header = Self.header(document)
        let id = try call(begin, Kiapi_Common_Commands_BeginCommitResponse.self).id
        var end = Kiapi_Common_Commands_EndCommit()
        end.id = id
        end.header = Self.header(document)
        do {
            let result = try changes()
            end.action = .cmaCommit
            end.message = message
            _ = try call(end, Kiapi_Common_Commands_EndCommitResponse.self)
            return result
        } catch {
            end.action = .cmaDrop
            _ = try? call(end, Kiapi_Common_Commands_EndCommitResponse.self)
            throw error
        }
    }

    // MARK: - Selection

    /// The ids of the footprints selected in the editor (a pad's footprint for a pad)
    public func selectedFootprints(_ document: Kiapi_Common_Types_DocumentSpecifier) throws -> [String] {
        var request = Kiapi_Common_Commands_GetSelection()
        request.header = Self.header(document)
        request.types = [.kotPcbFootprint, .kotPcbPad]
        var ids: [String] = []
        for item in try call(request, Kiapi_Common_Commands_SelectionResponse.self).items {
            if let footprint = try? Kiapi_Board_Types_FootprintInstance(unpackingAny: item) {
                ids.append(footprint.id.value)
            } else if let pad = try? Kiapi_Board_Types_Pad(unpackingAny: item), !pad.parent.value.isEmpty {
                ids.append(pad.parent.value)
            }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Selects these items in the editor, and nothing else
    public func select(_ ids: [String], in document: Kiapi_Common_Types_DocumentSpecifier) throws {
        var clear = Kiapi_Common_Commands_ClearSelection()
        clear.header = Self.header(document)
        _ = try call(clear, Google_Protobuf_Empty.self)
        guard !ids.isEmpty else { return }
        var add = Kiapi_Common_Commands_AddToSelection()
        add.header = Self.header(document)
        add.items = ids.map(Self.kiid)
        _ = try call(add, Kiapi_Common_Commands_SelectionResponse.self)
    }
}

extension Kiapi_Board_Types_FootprintInstance {
    /// Its reference, as the board shows it
    public var reference: String { referenceField.text.text.text }
}
