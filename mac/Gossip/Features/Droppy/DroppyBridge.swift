import Foundation
import Combine
import Darwin
import Security

/// Local API for the Droppy droplet: newline-delimited JSON over a `0600` Unix socket in Gossip's Application Support
/// folder. Only a client signed by Droppy's team may connect, checked by audit token, because the socket carries
/// notification content and lets the client reply to and dismiss phone notifications.
///
/// Server → client: `state` (devices, online, battery) on connect and on every change; `notification.posted` /
/// `notification.removed` as they arrive, plus every active one on connect with `replay: true`.
/// Client → server: `reply` (`deviceId`, `id`, `text`) and `dismiss` (`deviceId`, `id`).
///
/// All bookkeeping is on the main queue; each client gets a serial queue for its blocking writes.
final class DroppyBridge {
    static let allowedTeamID = "NARHG44L48"
    private static let maxCommandBytes = 64 * 1024

    static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Gossip/droppy.sock").path
    }

    private final class Client {
        let fd: Int32
        let writeQueue: DispatchQueue
        var readSource: DispatchSourceRead?
        var buffer = Data()

        init(fd: Int32) {
            self.fd = fd
            self.writeQueue = DispatchQueue(label: "dev.vmd1.gossip.droppybridge.client.\(fd)")
        }
    }

    private weak var transport: TransportManager?
    private let battery: BatterySyncManager
    private let notifications: NotificationMirrorManager
    private let trusted: TrustedDevicesStore

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Notifications each phone is still showing, by device id then Android id.
    private var active: [String: [String: NotificationPostedPayload]] = [:]

    init(transport: TransportManager, battery: BatterySyncManager, notifications: NotificationMirrorManager,
         trusted: TrustedDevicesStore = .shared) {
        self.transport = transport
        self.battery = battery
        self.notifications = notifications
        self.trusted = trusted
    }

    func start() {
        guard listenFD < 0, let transport else { return }
        guard openListener() else { return }

        transport.router.register(prefix: "notification.posted") { [weak self] envelope in
            DispatchQueue.main.async { self?.handlePosted(envelope) }
        }
        transport.router.register(prefix: "notification.removed") { [weak self] envelope in
            DispatchQueue.main.async { self?.handleRemoved(envelope) }
        }
        transport.addOnStateChanged { [weak self] change in
            guard change.slot == "notification.active" else { return }
            self?.handleActive(deviceId: change.deviceId, valueJSON: change.valueJSON)
        }

        // `@Published` fires before the new value is stored, so read it on the next main-queue turn.
        Publishers.Merge3(
            transport.$connectedDeviceIds.map { _ in () },
            battery.$batteryBySenderId.map { _ in () },
            trusted.$devices.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.broadcastState() }
        .store(in: &cancellables)
    }

    // MARK: - Socket

    private func openListener() -> Bool {
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { gossipError("Gossip: droppy bridge socket() failed: \(errno)"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            gossipError("Gossip: droppy bridge socket path too long")
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            gossipError("Gossip: droppy bridge bind/listen failed: \(errno)")
            close(fd)
            return false
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
        NSLog("Gossip: droppy bridge listening on \(path)")
        return true
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard Self.peerIsDroppy(fd) else {
            gossipError("Gossip: droppy bridge refused a client not signed by team \(Self.allowedTeamID)")
            close(fd)
            return
        }

        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(from: client)
        }
        source.setCancelHandler { close(fd) }
        client.readSource = source
        clients[fd] = client
        source.resume()

        send(stateMessage(), to: client)
        // `replay` marks what was already showing, so the client lists it without announcing it as new.
        for (deviceId, byId) in active {
            for posted in byId.values {
                var message = postedMessage(deviceId: deviceId, posted)
                message["replay"] = true
                send(message, to: client)
            }
        }
    }

    /// The connecting process must be signed by Droppy's team (Droppy and Droppy Playground both are). Checked by audit
    /// token rather than pid, which a process could recycle between `accept` and the check.
    private static func peerIsDroppy(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(allowedTeamID)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func read(from client: Client) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(client.fd, &chunk, chunk.count)
        guard count > 0 else { drop(client); return }
        client.buffer.append(contentsOf: chunk[0..<count])
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            handleCommand(Data(line))
        }
        if client.buffer.count > Self.maxCommandBytes { drop(client) }
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.fd) != nil else { return }
        client.readSource?.cancel()
    }

    private func send(_ message: [String: Any], to client: Client) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        let fd = client.fd
        client.writeQueue.async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    private func broadcast(_ message: [String: Any]) {
        for client in clients.values { send(message, to: client) }
    }

    // MARK: - Commands

    private func handleCommand(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let deviceId = object["deviceId"] as? String,
              let id = object["id"] as? String,
              trusted.devices.contains(where: { $0.deviceId == deviceId }) else { return }
        switch type {
        case "reply":
            guard let text = object["text"] as? String, !text.isEmpty, text.count <= 4000 else { return }
            notifications.sendReply(id: id, text: text, to: deviceId)
        case "dismiss":
            notifications.sendDismiss(id: id, to: deviceId)
        default:
            break
        }
    }

    // MARK: - Notifications

    private func handlePosted(_ envelope: Envelope) {
        guard let posted = try? notifications.decode(NotificationPostedPayload.self, from: envelope.payload) else { return }
        active[envelope.senderId, default: [:]][posted.id] = posted
        broadcast(postedMessage(deviceId: envelope.senderId, posted))
    }

    private func handleRemoved(_ envelope: Envelope) {
        guard let removed = try? notifications.decode(NotificationRemovedPayload.self, from: envelope.payload) else { return }
        forget(deviceId: envelope.senderId, id: removed.id)
    }

    /// The phone's list of what it still shows; anything else was a lost `notification.removed`.
    private func handleActive(deviceId: String, valueJSON: String?) {
        let ids = valueJSON
            .flatMap { try? JSONDecoder().decode(NotificationSyncPayload.self, from: Data($0.utf8)) }?.ids ?? []
        let live = Set(ids)
        for id in (active[deviceId] ?? [:]).keys where !live.contains(id) {
            forget(deviceId: deviceId, id: id)
        }
    }

    private func forget(deviceId: String, id: String) {
        guard active[deviceId]?.removeValue(forKey: id) != nil else { return }
        broadcast(["type": "notification.removed", "deviceId": deviceId, "id": id])
    }

    private func postedMessage(deviceId: String, _ posted: NotificationPostedPayload) -> [String: Any] {
        var message: [String: Any] = [
            "type": "notification.posted",
            "deviceId": deviceId,
            "id": posted.id,
            "appPackage": posted.appPackage,
            "appName": posted.appName,
            "title": posted.title,
            "body": posted.body,
            "hasReply": posted.hasReplyAction,
            "timestamp": posted.timestamp,
        ]
        if let icon = posted.iconBase64 { message["iconBase64"] = icon }
        return message
    }

    // MARK: - State

    private func broadcastState() {
        guard !clients.isEmpty else { return }
        broadcast(stateMessage())
    }

    private func stateMessage() -> [String: Any] {
        let online = transport?.connectedDeviceIds ?? []
        let devices: [[String: Any]] = trusted.devices.map { device in
            var entry: [String: Any] = [
                "id": device.deviceId,
                "name": device.deviceName,
                "type": device.deviceType.rawValue,
                "online": online.contains(device.deviceId),
            ]
            if let state = battery.batteryBySenderId[device.deviceId] {
                entry["battery"] = ["level": state.level, "charging": state.isCharging]
            }
            return entry
        }
        return ["type": "state", "devices": devices]
    }
}
