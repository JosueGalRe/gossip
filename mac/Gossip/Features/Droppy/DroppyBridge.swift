import AppKit
import Combine
import Darwin
import GossipCoreKit
import Security

/// Local API for the Droppy droplet: newline-delimited JSON over a `0600` Unix socket in Gossip's Application Support
/// folder. Only a client signed by Droppy's team may connect, checked by audit token, because the socket carries
/// notification content and messages and lets the client act on the phone.
///
/// Server → client:
/// - `state`: devices (online, through the relay or not, battery, Do Not Disturb, hotspot) and the peers this Mac is
///   ringing, on connect and on every change.
/// - `notification.posted` / `notification.removed` as they arrive, plus every active one on connect with `replay: true`.
/// - `media`: a device's now-playing state, or `nowPlaying: null` when it stopped. Artwork only when it changed.
/// - `messages.threads`, `messages.history` (the open conversation) and `messages.status` while the client has Messages open.
/// - `apps`: the phone's launchable apps (package, label, icon as base64 PNG) while the client has asked for them.
/// - `clipboard`: a peer's clipboard just landed on this Mac (`deviceId`, `text` cut to 500 characters, or `image`, a
///   small PNG thumbnail).
/// - `hotspot.result` (`deviceId`, `ok`) after a `hotspot` request; `error` (`message`) when a mirror or app window fails.
///
/// Client → server: `reply` / `dismiss` (`deviceId`, `id`), `action` (`deviceId`, `id`, `index`), `ring` (`deviceId`),
/// `open` (`target`: pair, mirror, messages), `media` (`action`, optional `seekMs`), `volume` (`direction`),
/// `messages.open` / `messages.close`, `messages.thread` (`threadId`), `messages.send` (`phoneId`, `address`, `body`),
/// `apps` (`deviceId`), `apps.close`, `app.open` (`deviceId`, `package`), `dnd` (`deviceId`, `enabled`) and `hotspot`
/// (`deviceId`, `enabled`).
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
    private let screenMirror: ScreenMirrorController
    private let hotspot: InstantHotspot
    private let clipboard: ClipboardSyncManager
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
    /// The phone whose app list the client is looking at (the droplet's settings), `nil` when none is.
    private var appsDeviceId: String?
    /// Each peer's Do Not Disturb, from its `dnd.state` slot.
    private var dnd: [String: Bool] = [:]

    /// Read from the transport's queue by `NotificationMirrorManager`, so it is kept apart from `clients`.
    private let clientCountLock = NSLock()
    private var clientCount = 0
    var hasClients: Bool { clientCountLock.withLock { clientCount > 0 } }

    init(transport: TransportManager, battery: BatterySyncManager, notifications: NotificationMirrorManager,
         ring: RingManager, media: MediaControlManager, messages: MessagesManager, screenMirror: ScreenMirrorController,
         hotspot: InstantHotspot, clipboard: ClipboardSyncManager, trusted: TrustedDevicesStore = .shared) {
        self.transport = transport
        self.battery = battery
        self.notifications = notifications
        self.ring = ring
        self.media = media
        self.messages = messages
        self.screenMirror = screenMirror
        self.hotspot = hotspot
        self.clipboard = clipboard
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
            guard let self else { return }
            if change.slot == "notification.active" {
                handleActive(deviceId: change.deviceId, valueJSON: change.valueJSON)
            } else if change.slot == GossipCoreKit.dndSlot() {
                let value = change.valueJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                dnd[change.deviceId] = value?["enabled"] as? Bool
                broadcastState()
            }
        }
        clipboard.onRemoteCopy = { [weak self] deviceId, text, png in
            DispatchQueue.main.async { self?.broadcastClipboard(from: deviceId, text: text, png: png) }
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

        // The BLE monitor publishes on every advertisement; only an actual change of a phone's hotspot is news.
        hotspot.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .map { [weak self] in self?.hotspotStates() ?? [:] }
            .removeDuplicates()
            .sink { [weak self] _ in self?.broadcastState() }
            .store(in: &cancellables)

        screenMirror.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.broadcast(["type": "error", "message": message]) }
            .store(in: &cancellables)

        // Icons arrive in batches right after the list; one broadcast for the lot.
        Publishers.Merge3(
            screenMirror.$appsByDevice.map { _ in () },
            screenMirror.$iconsByDevice.map { _ in () },
            screenMirror.$appsError.map { _ in () }
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.broadcastApps() }
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
        if clients.isEmpty { appsDeviceId = nil }
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
        case "apps":
            // What Gossip already has right away, then the phone's fresh list and any new icons.
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let transport else { return }
            appsDeviceId = deviceId
            broadcastApps()
            screenMirror.requestApps(deviceId: deviceId, transport: transport)
        case "apps.close":
            appsDeviceId = nil
        case "app.open":
            // A phone app as its own Mac window; one already open comes forward.
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let package = string("package", 200),
                  let transport, let device = trusted.devices.first(where: { $0.deviceId == deviceId }) else { return }
            let label = screenMirror.appsByDevice[deviceId]?.first { $0.package == package }?.label ?? package
            let wasOpen = screenMirror.isAppOpen(package, on: deviceId)
            screenMirror.start(deviceId: deviceId, deviceName: device.deviceName, transport: transport,
                               app: .init(package: package, label: label))
            if wasOpen { NSApp.activate(ignoringOtherApps: true) }
        case "dnd":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let enabled = object["enabled"] as? Bool else { return }
            try? transport?.send(envelope: Envelope(type: "dnd.set", senderId: IdentityKeyStore.shared.deviceId,
                                                    recipientId: deviceId, payload: .object(["enabled": .bool(enabled)])))
        case "hotspot":
            guard let deviceId = string("deviceId", 200), isTrusted(deviceId), let enabled = object["enabled"] as? Bool else { return }
            hotspot.request(deviceId, enable: enabled) { [weak self] ok in
                self?.broadcast(["type": "hotspot.result", "deviceId": deviceId, "ok": ok])
            }
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
            if let max = live.max { entry["progressMax"] = max }
            if let base = live.chronometerBase { entry["chronometerBaseMs"] = base }
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

    private func broadcastClipboard(from deviceId: String, text: String?, png: Data?) {
        var message: [String: Any] = ["type": "clipboard", "deviceId": deviceId]
        if let text { message["text"] = String(text.prefix(500)) }
        if let png, let thumbnail = Self.thumbnail(png, maxSide: 240) { message["image"] = thumbnail.base64EncodedString() }
        guard message.count > 2 else { return }
        broadcast(message)
    }

    /// A PNG no larger than `maxSide` on its long edge, for a preview.
    private static func thumbnail(_ png: Data, maxSide: CGFloat) -> Data? {
        guard let image = NSImage(data: png), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Each phone's hotspot as the menu bar shows it: `"on"`, `"on <ssid>"` or `"off"`; phones with no reading left out.
    private func hotspotStates() -> [String: String] {
        guard FeatureSettings.shared.isEnabled(.hotspot) else { return [:] }
        var states: [String: String] = [:]
        for device in trusted.devices where device.deviceType == .androidPhone {
            guard let state = hotspot.state(for: device.deviceId) else { continue }
            states[device.deviceId] = state.enabled ? (state.ssid.map { "on \($0)" } ?? "on") : "off"
        }
        return states
    }

    private func broadcastApps() {
        guard let deviceId = appsDeviceId, let apps = screenMirror.appsByDevice[deviceId] else {
            if let deviceId = appsDeviceId, let error = screenMirror.appsError[deviceId] {
                broadcast(["type": "apps", "deviceId": deviceId, "apps": [], "error": error])
            }
            return
        }
        let icons = screenMirror.iconsByDevice[deviceId] ?? [:]
        let list: [[String: Any]] = apps.map { app in
            var entry: [String: Any] = ["package": app.package, "label": app.label]
            if let tiff = icons[app.package]?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                entry["icon"] = png.base64EncodedString()
            }
            return entry
        }
        broadcast(["type": "apps", "deviceId": deviceId, "apps": list])
    }

    private func broadcastState() {
        guard !clients.isEmpty else { return }
        broadcast(stateMessage())
    }

    private func stateMessage() -> [String: Any] {
        let online = transport?.connectedDeviceIds ?? []
        let relayed = transport?.relayedDeviceIds ?? []
        let hotspots = FeatureSettings.shared.isEnabled(.hotspot)
            ? Dictionary(uniqueKeysWithValues: trusted.devices.filter { $0.deviceType == .androidPhone }
                .compactMap { device in hotspot.state(for: device.deviceId).map { (device.deviceId, $0) } })
            : [:]
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
            if let enabled = dnd[device.deviceId] { entry["dnd"] = enabled }
            if let state = hotspots[device.deviceId] {
                var value: [String: Any] = ["enabled": state.enabled]
                if let ssid = state.ssid { value["ssid"] = ssid }
                entry["hotspot"] = value
            }
            return entry
        }
        return ["type": "state", "devices": devices, "ringing": Array(ring.ringingPeers)]
    }
}
