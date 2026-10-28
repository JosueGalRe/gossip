import Foundation

/// Files between this Mac and a paired device over the encrypted mesh connection (`file.*` in
/// `schema/message-types.md`): sends files one after another, slicing each into 1 MiB raw frames with at most 4 MiB in
/// flight, and receives into `~/Downloads`. Direct connections only, so a transfer never crawls through the relay.
///
/// Each transfer resumes where it stopped: when acknowledgements stop (a reconnect), the sender offers the file again
/// and the receiver answers with the bytes it already holds. All file work happens on one serial queue; progress is
/// published on the main queue.
final class FileTransferManager: ObservableObject {
    struct Transfer: Equatable, Identifiable {
        enum State: String { case waiting, active, done, failed, cancelled }

        let id: String
        let deviceId: String
        let name: String
        let size: Int64
        let outgoing: Bool
        var done: Int64 = 0
        var state: State = .waiting
    }

    /// Every transfer this session, by id; finished ones stay so the UI can say how they ended.
    @Published private(set) var transfers: [String: Transfer] = [:]
    /// A file arrived and was saved (main queue).
    var onReceived: ((_ deviceId: String, _ url: URL) -> Void)?

    private let transport: TransportManager
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.files")
    private var timer: DispatchSourceTimer?

    private struct Outgoing {
        let id: String
        let deviceId: String
        let url: URL
        let name: String
        let handle: FileHandle
        var logic: FileTransferLogic.Sending
        var accepted = false
        var lastOffer = Date.distantPast
        var lastProgress = Date()
    }

    private struct Incoming {
        let senderId: String
        let name: String
        let size: Int64
        let partURL: URL
        let handle: FileHandle
        var received: Int64 = 0
        var lastActivity = Date()
    }

    private var pending: [Outgoing] = []
    private var current: Outgoing?
    private var incoming: [String: Incoming] = [:]
    /// Transfers received recently, so a re-sent offer for one gets "complete" instead of a second copy.
    private var finished: [(id: String, size: Int64)] = []
    private var lastPublished: [String: Date] = [:]

    private static let offerRetry: TimeInterval = 3
    private static let stallResend: TimeInterval = 10
    private static let giveUp: TimeInterval = 60
    private static let abandonPartial: TimeInterval = 10 * 60

    init(transport: TransportManager) {
        self.transport = transport
        transport.router.register(prefix: "file.") { [weak self] envelope in
            self?.queue.async { self?.handle(envelope) }
        }
        transport.addOnRawFrameReceived { [weak self] envelope, data in
            guard envelope.type == "file.chunk" else { return }
            self?.queue.async { self?.handleChunk(envelope, data) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Sending

    /// Queues `urls` for `deviceId`. Main thread. Returns why it can't, or `nil`: the device must be connected
    /// directly (not through the relay), and only regular files go.
    func send(_ urls: [URL], to deviceId: String) -> String? {
        guard transport.connectedDeviceIds.contains(deviceId), !transport.isRelayed(deviceId) else {
            return "The phone needs to be on the same network as this Mac to send files."
        }
        var queued: [Outgoing] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  Int64(size) <= FileTransferLogic.maxFileBytes,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let id = UUID().uuidString
            queued.append(Outgoing(id: id, deviceId: deviceId, url: url, name: url.lastPathComponent, handle: handle,
                                   logic: .init(size: Int64(size))))
            transfers[id] = Transfer(id: id, deviceId: deviceId, name: url.lastPathComponent, size: Int64(size), outgoing: true)
        }
        guard !queued.isEmpty else { return "Only files (not folders) up to 4 GB can be sent." }
        queue.async {
            self.pending.append(contentsOf: queued)
            if self.current == nil { self.startNext() }
        }
        return nil
    }

    /// Stops a transfer either way: the other side is told and drops what it has.
    func cancel(_ id: String) {
        queue.async {
            if self.current?.id == id, let current = self.current {
                self.message("file.cancel", to: current.deviceId, ["transferId": .string(id), "reason": .string("cancelled")])
                self.finishOutgoing(.cancelled)
            } else if let index = self.pending.firstIndex(where: { $0.id == id }) {
                try? self.pending.remove(at: index).handle.close()
                self.publish(id, state: .cancelled)
            } else if let file = self.incoming[id] {
                self.message("file.cancel", to: file.senderId, ["transferId": .string(id), "reason": .string("cancelled")])
                self.dropIncoming(id, state: .cancelled)
            }
        }
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else { return }
        var next = pending.removeFirst()
        next.lastProgress = Date()
        current = next
        publish(next.id, state: .active)
        offer()
    }

    private func offer() {
        guard var current else { return }
        current.lastOffer = Date()
        self.current = current
        var payload: [String: JSONValue] = [
            "transferId": .string(current.id), "name": .string(current.name), "size": .number(Double(current.logic.size)),
        ]
        if let type = try? current.url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType {
            payload["mime"] = .string(type)
        }
        message("file.offer", to: current.deviceId, payload)
    }

    private func pump() {
        guard var current, current.accepted else { return }
        while let chunk = current.logic.nextChunk {
            guard (try? current.handle.seek(toOffset: UInt64(chunk.offset))) != nil,
                  let data = try? current.handle.read(upToCount: chunk.length), data.count == chunk.length else {
                self.current = current
                failOutgoing("storage")
                return
            }
            message("file.chunk", to: current.deviceId,
                    ["transferId": .string(current.id), "offset": .number(Double(chunk.offset))], raw: data)
            current.logic.sent(chunk.length)
        }
        self.current = current
    }

    private func finishOutgoing(_ state: Transfer.State) {
        guard let current else { return }
        try? current.handle.close()
        publish(current.id, done: current.logic.acked, state: state)
        self.current = nil
        startNext()
    }

    private func failOutgoing(_ reason: String) {
        guard let current else { return }
        message("file.cancel", to: current.deviceId, ["transferId": .string(current.id), "reason": .string(reason)])
        finishOutgoing(.failed)
    }

    // MARK: - Receiving

    private func handle(_ envelope: Envelope) {
        let payload = envelope.payload
        guard let id = payload["transferId"]?.stringValue, !id.isEmpty, id.count <= 64 else { return }
        switch envelope.type {
        case "file.offer":
            receiveOffer(id, from: envelope.senderId, payload)
        case "file.accept":
            guard current?.id == id, current?.deviceId == envelope.senderId,
                  let offset = payload["offset"]?.numberValue else { return }
            current?.logic.accept(offset: Int64(offset))
            current?.accepted = true
            current?.lastProgress = Date()
            pump()
        case "file.ack":
            guard var sending = current, sending.id == id, sending.deviceId == envelope.senderId,
                  let received = payload["received"]?.numberValue else { return }
            if sending.logic.ack(received: Int64(received)) {
                sending.lastProgress = Date()
                publishThrottled(id, done: Int64(received))
            }
            current = sending
            if payload["complete"]?.boolValue == true || sending.logic.isComplete {
                finishOutgoing(.done)
            } else {
                pump()
            }
        case "file.cancel":
            if current?.id == id, current?.deviceId == envelope.senderId {
                finishOutgoing(payload["reason"]?.stringValue == "cancelled" ? .cancelled : .failed)
            } else if incoming[id]?.senderId == envelope.senderId {
                dropIncoming(id, state: .cancelled)
            }
        default:
            break // file.chunk arrives with its bytes through the raw-frame handler
        }
    }

    private func receiveOffer(_ id: String, from senderId: String, _ payload: JSONValue) {
        guard TrustedDevicesStore.shared.devices.contains(where: { $0.deviceId == senderId }),
              let name = payload["name"]?.stringValue, let sizeValue = payload["size"]?.numberValue else { return }
        let size = Int64(sizeValue)
        if let done = finished.first(where: { $0.id == id }) {
            message("file.ack", to: senderId, ["transferId": .string(id), "received": .number(Double(done.size)),
                                               "complete": .bool(true)])
            return
        }
        if let file = incoming[id] {
            guard file.senderId == senderId else { return }
            message("file.accept", to: senderId, ["transferId": .string(id), "offset": .number(Double(file.received))])
            return
        }
        guard size >= 0, size <= FileTransferLogic.maxFileBytes else {
            message("file.cancel", to: senderId, ["transferId": .string(id), "reason": .string("too_large")])
            return
        }
        guard let folder = Self.partsFolder else { return refuse(id, senderId) }
        let partURL = folder.appendingPathComponent("\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: partURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partURL) else { return refuse(id, senderId) }
        let file = Incoming(senderId: senderId, name: FileTransferLogic.sanitizedName(name), size: size,
                            partURL: partURL, handle: handle)
        incoming[id] = file
        DispatchQueue.main.async {
            self.transfers[id] = Transfer(id: id, deviceId: senderId, name: file.name, size: size, outgoing: false, state: .active)
        }
        message("file.accept", to: senderId, ["transferId": .string(id), "offset": .number(0)])
        if size == 0 { complete(id) }
    }

    private func refuse(_ id: String, _ senderId: String) {
        message("file.cancel", to: senderId, ["transferId": .string(id), "reason": .string("storage")])
    }

    private func handleChunk(_ envelope: Envelope, _ data: Data) {
        guard let id = envelope.payload["transferId"]?.stringValue,
              let offset = envelope.payload["offset"]?.numberValue else { return }
        guard var file = incoming[id] else {
            if !finished.contains(where: { $0.id == id }) {
                message("file.cancel", to: envelope.senderId, ["transferId": .string(id), "reason": .string("unknown")])
            }
            return
        }
        guard file.senderId == envelope.senderId else { return }
        switch FileTransferLogic.decide(offset: Int64(offset), length: data.count, received: file.received, size: file.size) {
        case .write:
            do {
                try file.handle.write(contentsOf: data)
            } catch {
                message("file.cancel", to: file.senderId, ["transferId": .string(id), "reason": .string("storage")])
                return dropIncoming(id, state: .failed)
            }
            file.received += Int64(data.count)
            file.lastActivity = Date()
            incoming[id] = file
            publishThrottled(id, done: file.received)
        case .ignore:
            break
        case .reject:
            message("file.cancel", to: file.senderId, ["transferId": .string(id), "reason": .string("too_large")])
            return dropIncoming(id, state: .failed)
        }
        if file.received == file.size {
            complete(id)
        } else {
            message("file.ack", to: file.senderId, ["transferId": .string(id), "received": .number(Double(file.received))])
        }
    }

    /// Moves the whole file into Downloads under a free name and tells the sender.
    private func complete(_ id: String) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        try? file.handle.close()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = FileTransferLogic.uniqueName(file.name) {
            FileManager.default.fileExists(atPath: downloads.appendingPathComponent($0).path)
        }
        let destination = downloads.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: file.partURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: file.partURL)
            message("file.cancel", to: file.senderId, ["transferId": .string(id), "reason": .string("storage")])
            publish(id, state: .failed)
            return
        }
        finished.append((id, file.size))
        if finished.count > 64 { finished.removeFirst(finished.count - 64) }
        message("file.ack", to: file.senderId, ["transferId": .string(id), "received": .number(Double(file.size)),
                                                "complete": .bool(true)])
        publish(id, done: file.size, state: .done)
        DispatchQueue.main.async { self.onReceived?(file.senderId, destination) }
    }

    private func dropIncoming(_ id: String, state: Transfer.State) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        try? file.handle.close()
        try? FileManager.default.removeItem(at: file.partURL)
        publish(id, state: state)
    }

    private static var partsFolder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gossip/Incoming", isDirectory: true)
        PrivateFile.ensureDirectory(dir)
        return dir
    }

    // MARK: - Timing

    private func tick() {
        let now = Date()
        if let current {
            let quiet = now.timeIntervalSince(current.lastProgress)
            if quiet > Self.giveUp {
                failOutgoing("timeout")
            } else if !current.accepted, now.timeIntervalSince(current.lastOffer) > Self.offerRetry {
                offer()
            } else if current.accepted, quiet > Self.stallResend, now.timeIntervalSince(current.lastOffer) > Self.stallResend {
                // Acknowledgements stopped (a reconnect loses what was in flight): ask where to resume.
                offer()
            }
        }
        for (id, file) in incoming where now.timeIntervalSince(file.lastActivity) > Self.abandonPartial {
            dropIncoming(id, state: .failed)
        }
    }

    // MARK: - Plumbing

    private func message(_ type: String, to deviceId: String, _ payload: [String: JSONValue], raw: Data? = nil) {
        let envelope = Envelope(type: type, senderId: IdentityKeyStore.shared.deviceId, recipientId: deviceId, ttl: 0,
                                hasRawFollowup: raw != nil, payload: .object(payload))
        if let raw { try? transport.send(envelope, withRawFollowup: raw) } else { try? transport.send(envelope: envelope) }
    }

    private func publish(_ id: String, done: Int64? = nil, state: Transfer.State) {
        DispatchQueue.main.async {
            guard var transfer = self.transfers[id] else { return }
            if let done { transfer.done = done }
            transfer.state = state
            self.transfers[id] = transfer
        }
    }

    /// Progress at most four times a second per transfer.
    private func publishThrottled(_ id: String, done: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastPublished[id] ?? .distantPast) > 0.25 else { return }
        lastPublished[id] = now
        publish(id, done: done, state: .active)
    }
}
