import Foundation
import Security

/// Where a small secret blob (the identity keys, the trust roster) lives: the login Keychain when this build has a team
/// ID (`KeychainBlobStore`), otherwise a `0600` file under Application Support (`FileBlobStore`), written atomically via
/// `PrivateFile`. Tests get a separate scratch directory per process so parallel runs do not share state.
protocol SecretBlobStore {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
}

/// Picks the blob store for `account`.
///
/// Upstream moved these from the Keychain to private files because a self-signed build has no team ID: the login
/// Keychain's partition list then names one build's code hash, and every rebuild asks for the login password again.
/// Signed with a team (a free Apple Development certificate is enough), the list names `teamid:…`, which every build
/// of that team matches, so the app reads its own items without a prompt. Such a build keeps the secrets in the
/// Keychain, out of reach of other processes running as this user, and moves any existing file there on first read.
/// A team-less build still uses the files.
enum ProductionBlobStore {
    static var isRunningUnderTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    static func make(account: String) -> SecretBlobStore {
        let file = FileBlobStore(url: directory.appendingPathComponent("\(account).secret"))
        guard !isRunningUnderTest, hasTeamIdentifier else { return file }
        return KeychainBlobStore(account: account, legacyFile: file)
    }

    /// Whether this process is signed with a team ID (Apple Development or Developer ID), not ad hoc or self-signed.
    static let hasTeamIdentifier: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }()

    private static let directory: URL = {
        let dir: URL
        if isRunningUnderTest {
            // Per test process, so parallel runs do not share state; the system cleans the temporary directory.
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("gossip-test-stores-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("Gossip/secrets", isDirectory: true)
        }
        PrivateFile.ensureDirectory(dir)
        return dir
    }()
}

/// A `0600` file written atomically via `PrivateFile`.
struct FileBlobStore: SecretBlobStore {
    let url: URL

    func read() -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data) -> Bool { PrivateFile.write(data, to: url) }
}

/// A generic-password item in the login Keychain. The file an earlier build wrote is moved in on first read, and
/// removed only once the Keychain holds its contents, so a failure never loses the identity (which would mean pairing
/// every device again).
struct KeychainBlobStore: SecretBlobStore {
    static let service = "dev.vmd1.gossip.secrets"
    let account: String
    let legacyFile: FileBlobStore

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &result)
        // A nil answer makes the caller create a new identity (and every device would have to pair again), so a
        // transient failure, such as a Keychain still locked right after login, is retried before giving up.
        for _ in 0..<5 where status != errSecSuccess && status != errSecItemNotFound {
            Thread.sleep(forTimeInterval: 1)
            status = SecItemCopyMatching(lookup as CFDictionary, &result)
        }
        if status == errSecSuccess, let data = result as? Data { return data }
        if status != errSecItemNotFound {
            gossipError("Gossip: Keychain read of \(account) failed (\(status)); using the file")
        }
        guard let data = legacyFile.read() else { return nil }
        if write(data) { NSLog("Gossip: moved \(account) from its file into the Keychain") }
        return data
    }

    func write(_ data: Data) -> Bool {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Gossip \(account)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            gossipError("Gossip: Keychain write of \(account) failed (\(status)); keeping the file")
            return legacyFile.write(data)
        }
        try? FileManager.default.removeItem(at: legacyFile.url)
        return true
    }
}
