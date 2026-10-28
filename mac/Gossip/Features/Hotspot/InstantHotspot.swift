import Combine
import Foundation

/// A phone's Instant Hotspot as this Mac sees and drives it, shared by the menu bar and the Droppy bridge: the merged
/// on/off state, and the request that turns it on or off over BLE GATT (it needs no mesh connection) and joins the
/// network after a successful "on".
final class InstantHotspot: ObservableObject {
    private let states: HotspotStateManager
    private let ble: BLEProximityMonitor
    /// Requests in flight, one per phone; the menu shows a spinner for them.
    @Published private var clients: [String: HotspotGattClient] = [:]
    private var autoConnect: HotspotAutoConnect?
    /// The state the phone itself just confirmed over GATT. The BLE advertisement bit and the mesh report both lag a
    /// real toggle by several seconds, so this wins until the merged state catches up (or `overrideLifetime` passes).
    @Published private var overrides: [String: Override] = [:]
    private static let overrideLifetime: TimeInterval = 30
    private var cancellables = Set<AnyCancellable>()

    private struct Override {
        let enabled: Bool
        let at: Date
    }

    init(states: HotspotStateManager, ble: BLEProximityMonitor) {
        self.states = states
        self.ble = ble
        // Either source changing changes the merged state.
        states.objectWillChange.merge(with: ble.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Merges the two hotspot-state sources: `hotspot.state`'s mesh report (`HotspotStateManager`, richer — carries the
    /// SSID, works at any range) and the BLE advertisement's own on/off bit (`BLEProximityMonitor.isHotspotOn`, live
    /// even with no mesh connection at all). With mesh as the only source the indicator went stale the moment the mesh
    /// connection to the phone dropped, and pressing the button against that stale belief sent the wrong request.
    /// Prefers the BLE bit's `enabled` value whenever the phone is BLE-nearby (fresher by construction), keeping the
    /// mesh report's `ssid` either way; falls back to a BLE-only or mesh-only state when just one source has data, and
    /// to `nil` when neither does.
    func state(for deviceId: String) -> HotspotState? {
        let underlying = underlyingState(for: deviceId)
        if let override = overrides[deviceId], Date().timeIntervalSince(override.at) < Self.overrideLifetime,
           underlying?.enabled != override.enabled {
            return HotspotState(enabled: override.enabled, ssid: override.enabled ? underlying?.ssid : nil)
        }
        return underlying
    }

    func isRequesting(_ deviceId: String) -> Bool { clients[deviceId] != nil }

    private func underlyingState(for deviceId: String) -> HotspotState? {
        let meshState = states.hotspotStateBySenderId[deviceId]
        guard ble.nearbyDeviceIds.contains(deviceId) else { return meshState }
        return HotspotState(enabled: ble.isHotspotOn(deviceId: deviceId), ssid: meshState?.ssid)
    }

    /// Requests `enable` from the phone over BLE GATT, then joins its network on a successful "on". `done` gets whether
    /// the phone confirmed the request; failures are also written to the BLE debug log. Main thread.
    func request(_ deviceId: String, enable: Bool, done: ((Bool) -> Void)? = nil) {
        guard let peripheralId = ble.peripheralIdentifierByDeviceId[deviceId] else {
            done?(false)
            return
        }
        let client = HotspotGattClient()
        clients[deviceId] = client
        client.requestToggle(providerId: deviceId, peripheralIdentifier: peripheralId, enable: enable) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.clients[deviceId] = nil
                switch result {
                case .failed(let reason):
                    gossipError("Gossip: " + "requestHotspot failed: \(reason)")
                    done?(false)
                case .success(let enabled, let ssid, let passphrase):
                    self.overrides[deviceId] = Override(enabled: enabled, at: Date())
                    done?(enabled == enable)
                    guard enable, enabled, let ssid, let passphrase else { return }
                    let autoConnect = HotspotAutoConnect()
                    self.autoConnect = autoConnect
                    autoConnect.connect(ssid: ssid, passphrase: passphrase) { connected in
                        if !connected { NSLog("Gossip: " + "requestHotspot: could not auto-connect to \(ssid)") }
                    }
                }
            }
        }
    }
}
