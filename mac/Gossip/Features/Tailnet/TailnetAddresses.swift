import Darwin
import Foundation

/// Tailscale, set up by itself (Android's `TailnetAddresses` is the other half): this Mac publishes its tailnet address
/// as the `network.tailnet` state slot and keeps every paired device's, so the fallback dial reaches a device that left
/// the local network without anyone typing its address. A fallback address entered by hand still wins. Only addresses
/// in Tailscale's range (100.64.0.0/10) are kept, so a peer can't point this Mac's dials anywhere else.
final class TailnetAddresses {
    static let slot = "network.tailnet"
    private static let defaultsKey = "dev.vmd1.gossip.tailnetHosts"

    private weak var transport: TransportManager?
    private var timer: Timer?
    private var published = false
    private var lastPublished: String?

    init(transport: TransportManager) {
        self.transport = transport
        transport.addOnStateChanged { [weak self] change in
            guard change.slot == Self.slot else { return }
            self?.store(change)
        }
        publish()
        // Tailscale comes and goes (and its address with it); the core ignores an unchanged value.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.publish() }
    }

    /// The tailnet address `deviceId` last published, if any.
    func host(for deviceId: String) -> String? { hosts[deviceId] }

    private var hosts: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func store(_ change: TransportManager.StateChange) {
        let value = change.valueJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        var all = hosts
        all[change.deviceId] = (value?["ipv4"] as? String).flatMap { Self.isTailnet($0) ? $0 : nil }
        UserDefaults.standard.set(all, forKey: Self.defaultsKey)
    }

    private func publish() {
        let own = Self.ownAddress()
        guard !published || own != lastPublished else { return }
        published = true
        lastPublished = own
        transport?.setState(slot: Self.slot, valueJSON: own.map { #"{"ipv4":"\#($0)"}"# })
    }

    /// An IPv4 address in Tailscale's 100.64.0.0/10.
    static func isTailnet(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1]!)
    }

    /// This Mac's tailnet address while Tailscale is connected (one of its utun interfaces), else `nil`.
    static func ownAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if isTailnet(ip) { return ip }
        }
        return nil
    }
}
