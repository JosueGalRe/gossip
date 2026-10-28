import Foundation
import Combine
import Darwin
import Security

/// Local API for the Droppy droplet: newline-delimited JSON over a `0600` Unix socket in Gossip's Application Support
/// folder. Only a client signed by Droppy's team may connect, checked by audit token, because the socket carries
/// notification content and messages and lets the client act on the phone.
///
/// Server → client:
/// - `state`: devices (online, through the relay or not, battery) and the peers this Mac is ringing, on connect and on
///   every change.
/// - `notification.posted` / `notification.removed` as they arrive, plus every active one on connect with `replay: true`.
/// - `media`: a device's now-playing state, or `nowPlaying: null` when it stopped. Artwork only when it changed.
/// - `messages.threads`, `messages.history` (the open conversation) and `messages.status` while the client has Messages open.
///
/// Client → server: `reply` / `dismiss` (`deviceId`, `id`), `action` (`deviceId`, `id`, `index`), `ring` (`deviceId`),
/// `open` (`target`: pair, mirror, messages), `media` (`action`, optional `seekMs`), `volume` (`direction`),
/// `messages.open` / `messages.close`, `messages.thread` (`threadId`) and `messages.send` (`phoneId`, `address`, `body`).
///
/// All bookkeeping is on the main queue; each client gets a serial queue for its blocking writes.
final class DroppyBridge {
    static let allowedTeamID = "NARHG44L48"
    private static let maxCommandBytes = 64 * 1024
    private static let openTargets: Set<String> = ["pair", "mirror", "messages"]

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

    /// Opens a `connect://` URL in this process (pairing, mirroring and Messages windows). Set by `ConnectApp`.
    var openURLs: (([URL]) -> Void)?

    private weak var transport: TransportManager?
    private let battery: BatterySyncManager
    private let notifications: NotificationMirrorManager
    private let ring: RingManager
    private let media: MediaControlManager
    private let messages: MessagesManager
    private let trusted: TrustedDevicesStore

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Notifications each phone is still showing, by device id then Android id.
    private var active: [String: [String: NotificationPostedPayload]] = [:]
    /// What each device last reported as now playing, and the artwork already sent for it.
    private var nowPlaying: [String: NowPlayingState] = [:]
    private var sentArtwork: [String: Data] = [:]
    /// Whether the droplet has Messages open, so `MessagesManager` keeps refreshing on its behalf.
    private var messagesOpen = false

    /// Read from the transport's queue by `NotificationMirrorManager`, so it is kept apart from `clients`.
    private let clientCountLock = NSLock()
    private var clientCount = 0
    var hasClients: Bool { clientCountLock.withLock { clientCount > 0 } }

    init(transport: TransportManager, battery: BatterySyncManager, notifications: NotificationMirrorManager,
         ring: RingManager, media: MediaControlManager, messages: MessagesManager, trusted: TrustedDevicesStore = .shared) {
        self.transport = transport
        self.battery = battery
        self.notifications = notifications
        self.ring = ring
        self.media = media
        self.messages = messages
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
        Publishers.Merge5(
            transport.$connectedDeviceIds.map { _ in () },
            transport.$relayedDeviceIds.map { _ in () },
            battery.$batteryBySenderId.map { _ in () },
            trusted.$devices.map { _ in () },
            ring.$ringingPeers.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.broadcastState() }
        .store(in: &cancellables)

        media.$nowPlayingByDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latest in self?.mediaChanged(latest) }
            .store(in: &cancellables)

        Publishers.Merge3(
            messages.$threads.map { _ in () },
            messages.$error.map { _ in () },
            messages.$loading.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.broadcastThreads() }
        .store(in: &cancellables)

        Publishers.CombineLatest(messages.$messages, messages.$openThreadId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.broadcastHistory() }
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
        clientCountLock.withLock { clientCount = clients.count }
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
        for (deviceId, state) in nowPlaying {
            send(mediaMessage(deviceId: deviceId, state, includeArtwork: true), to: client)
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
        clientCountLock.withLock { clientCount = clients.count }
        client.readSource?.cancel()
        if clients.isEmpty, messagesOpen {
            messagesOpen = false
            messages.close()
        }
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
              let type = object["type"] as? String else { return }
        let string = { (key: String, limit: Int) -> String? in
            guard let value = object[key] as? String, !value.isEmpty, value.count <= limit else { return nil }
            return value
        }
        let isTrusted = { (deviceId: String) in self.trusted.devices.contains { $0.deviceId == deviceId } }

        switch type {
        case "reply":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let id = string("id", 1000),
                  let text = string("text", 4000) else { return }
            notifications.sendReply(id: id, text: text, to: deviceId)
        case "dismiss":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let id = string("id", 1000) else { return }
            notifications.sendDismiss(id: id, to: deviceId)
        case "action":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let id = string("id", 1000),
                  let index = object["index"] as? Int, (0..<10).contains(index) else { return }
            notifications.sendAction(id: id, index: index, to: deviceId)
        case "ring":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId) else { return }
            ring.toggleRing(deviceId)
        case "open":
            guard let target = string("target", 20), Self.openTargets.contains(target),
                  let url = URL(string: "connect://\(target)") else { return }
            openURLs?([url])
        case "media":
            guard let action = string("action", 20).flatMap(MediaCommandAction.init(rawValue:)) else { return }
            // A seek travels with the command that keeps the current state: play while playing, pause while paused.
            let seekMs = (object["seekMs"] as? Int).map { max(0, $0) }
            media.sendCommand(action, seekMs: seekMs)
        case "volume":
            guard let direction = string("direction", 4), direction == "up" || direction == "down" else { return }
            media.sendVolume(up: direction == "up")
        case "messages.open":
            messagesOpen = true
            messages.open()
            broadcastThreads()
        case "messages.close":
            messagesOpen = false
            messages.close()
        case "messages.thread":
            guard let threadId = string("threadId", 400), messages.threads.contains(where: { $0.id == threadId }) else { return }
            messages.openThread(threadId)
        case "messages.send":
            guard let phoneId = string("phoneId", 200), isTrusted(phoneId), let address = string("address", 64),
                  let body = string("body", 2000) else { return }
            messages.send(body: body, to: address, via: phoneId)
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
        if let avatar = posted.avatarBase64 { message["avatarBase64"] = avatar }
        if let picture = posted.pictureBase64 { message["pictureBase64"] = picture }
        if let actions = posted.actions, !actions.isEmpty {
            message["actions"] = actions.map { ["index": $0.index, "title": $0.title] as [String: Any] }
        }
        if let replies = posted.smartReplies, !replies.isEmpty { message["smartReplies"] = replies }
        if let live = posted.live {
            var entry: [String: Any] = [
                "indeterminate": live.indeterminate ?? false,
                "countDown": live.countDown ?? false,
                "promoted": live.promoted ?? false,
            ]
            if let category = live.category { entry["category"] = category }
            if let progress = live.progress { entry["progress"] = progress }
            if let max = live.progressMax { entry["progressMax"] = max }
            if let base = live.chronometerBaseMs { entry["chronometerBaseMs"] = base }
            message["live"] = entry
        }
        return message
    }

    // MARK: - Media

    private func mediaChanged(_ latest: [String: NowPlayingState]) {
        for (deviceId, state) in latest where nowPlaying[deviceId] != state {
            nowPlaying[deviceId] = state
            let artworkChanged = sentArtwork[deviceId] != state.artworkData
            sentArtwork[deviceId] = state.artworkData
            broadcast(mediaMessage(deviceId: deviceId, state, includeArtwork: artworkChanged))
        }
        for deviceId in nowPlaying.keys where latest[deviceId] == nil {
            nowPlaying[deviceId] = nil
            sentArtwork[deviceId] = nil
            broadcast(["type": "media", "deviceId": deviceId, "nowPlaying": NSNull()])
        }
    }

    private func mediaMessage(deviceId: String, _ state: NowPlayingState, includeArtwork: Bool) -> [String: Any] {
        var playing: [String: Any] = [
            "title": state.title,
            "artist": state.artist,
            "isPlaying": state.isPlaying,
            "positionMs": state.positionMs,
            "durationMs": state.durationMs,
            "packageName": state.packageName,
        ]
        if includeArtwork, let artwork = state.artworkData { playing["artworkBase64"] = artwork.base64EncodedString() }
        return ["type": "media", "deviceId": deviceId, "nowPlaying": playing]
    }

    // MARK: - Messages

    private func broadcastThreads() {
        guard messagesOpen, !clients.isEmpty else { return }
        let threads: [[String: Any]] = messages.threads.prefix(100).map { thread in
            [
                "id": thread.id,
                "phoneId": thread.phoneId,
                "title": thread.title,
                "address": thread.address,
                "snippet": thread.snippet,
                "date": thread.date.timeIntervalSince1970,
                "outgoing": thread.outgoing,
                "unread": thread.unread,
            ]
        }
        broadcast(["type": "messages.threads", "threads": threads])
        var status: [String: Any] = ["type": "messages.status", "loading": messages.loading]
        if let error = messages.error { status["error"] = error }
        broadcast(status)
    }

    private func broadcastHistory() {
        guard messagesOpen, !clients.isEmpty, let threadId = messages.openThreadId else { return }
        let items: [[String: Any]] = messages.messages.suffix(100).map { message in
            [
                "id": message.id,
                "date": message.date.timeIntervalSince1970,
                "outgoing": message.outgoing,
                "body": message.body,
                "sending": message.sending,
                "failed": message.failed,
            ]
        }
        broadcast(["type": "messages.history", "threadId": threadId, "messages": items])
    }

    // MARK: - State

    private func broadcastState() {
        guard !clients.isEmpty else { return }
        broadcast(stateMessage())
    }

    private func stateMessage() -> [String: Any] {
        let online = transport?.connectedDeviceIds ?? []
        let relayed = transport?.relayedDeviceIds ?? []
        let devices: [[String: Any]] = trusted.devices.map { device in
            var entry: [String: Any] = [
                "id": device.deviceId,
                "name": device.deviceName,
                "type": device.deviceType.rawValue,
                "online": online.contains(device.deviceId) || relayed.contains(device.deviceId),
                "relayed": relayed.contains(device.deviceId),
            ]
            if let state = battery.batteryBySenderId[device.deviceId] {
                entry["battery"] = ["level": state.level, "charging": state.isCharging]
            }
            return entry
        }
        return ["type": "state", "devices": devices, "ringing": Array(ring.ringingPeers)]
    }
}
