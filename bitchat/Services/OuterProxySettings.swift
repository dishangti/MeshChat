import BitFoundation
#if os(macOS)
import CFNetwork
#endif
import Darwin
import Foundation
import Tor

/// Persists and applies the optional proxy that sits outside direct or Tor relay traffic.
enum OuterProxyMode: String, CaseIterable {
    case systemDefault
    case custom
}

enum OuterProxyKind: String, CaseIterable {
    case httpConnect
    case socks5

    var torKind: TorUpstreamProxy.Kind {
        switch self {
        case .httpConnect: return .httpConnect
        case .socks5: return .socks5
        }
    }
}

struct OuterProxyDraft: Equatable {
    var mode: OuterProxyMode
    var kind: OuterProxyKind
    var host: String
    var port: String
    var username: String
    var password: String
}

enum OuterProxySettingsError: Error, Equatable {
    case invalidHost
    case invalidPort
    case incompleteCredentials
    case oversizedCredentials
    case passwordSaveFailed
}

enum OuterProxySettings {
    static let didChangeNotification = Notification.Name("OuterProxySettings.didChange")

    private static let modeKey = "outerProxy.mode"
    private static let kindKey = "outerProxy.kind"
    private static let hostKey = "outerProxy.host"
    private static let portKey = "outerProxy.port"
    private static let usernameKey = "outerProxy.username"
    private static let legacyModeKey = "macProxy.mode"
    private static let legacyKindKey = "macProxy.kind"
    private static let legacyHostKey = "macProxy.host"
    private static let legacyPortKey = "macProxy.port"
    private static let legacyUsernameKey = "macProxy.username"
    private static let passwordAccount = "outer_proxy_password"
    private static let passwordService = "chat.meshchat.proxy"
    private static let maxFieldBytes = 1_024

    static func loadDraft(
        defaults: UserDefaults = .standard,
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault()
    ) -> OuterProxyDraft {
        let modeValue = defaults.string(forKey: modeKey) ?? defaults.string(forKey: legacyModeKey) ?? ""
        let kindValue = defaults.string(forKey: kindKey) ?? defaults.string(forKey: legacyKindKey) ?? ""
        let mode = OuterProxyMode(rawValue: modeValue) ?? .systemDefault
        let kind = OuterProxyKind(rawValue: kindValue) ?? .httpConnect
        let password: String
        if mode == .custom {
            password = keychain.load(key: passwordAccount, service: passwordService)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } else {
            password = ""
        }
        return OuterProxyDraft(
            mode: mode,
            kind: kind,
            host: defaults.string(forKey: hostKey) ?? defaults.string(forKey: legacyHostKey) ?? "",
            port: defaults.string(forKey: portKey) ?? defaults.string(forKey: legacyPortKey) ?? "",
            username: defaults.string(forKey: usernameKey) ?? defaults.string(forKey: legacyUsernameKey) ?? "",
            password: password
        )
    }

    static func save(
        _ draft: OuterProxyDraft,
        defaults: UserDefaults = .standard,
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault()
    ) -> Result<TorUpstreamProxy?, OuterProxySettingsError> {
        let validated: TorUpstreamProxy?
        switch draft.mode {
        case .systemDefault:
            validated = nil
        case .custom:
            do {
                validated = try customProxy(from: draft)
            } catch let error as OuterProxySettingsError {
                return .failure(error)
            } catch {
                return .failure(.invalidHost)
            }
        }

        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.mode == .custom, !username.isEmpty {
            let result = keychain.saveWithResult(
                key: passwordAccount,
                data: Data(draft.password.utf8),
                service: passwordService,
                accessible: nil
            )
            guard case .success = result else { return .failure(.passwordSaveFailed) }
        } else {
            keychain.delete(key: passwordAccount, service: passwordService)
        }

        defaults.set(draft.mode.rawValue, forKey: modeKey)
        defaults.set(draft.kind.rawValue, forKey: kindKey)
        defaults.set(draft.host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: hostKey)
        defaults.set(draft.port.trimmingCharacters(in: .whitespacesAndNewlines), forKey: portKey)
        defaults.set(username, forKey: usernameKey)
        [legacyModeKey, legacyKindKey, legacyHostKey, legacyPortKey, legacyUsernameKey].forEach {
            defaults.removeObject(forKey: $0)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return .success(validated)
    }

    static func reset(
        defaults: UserDefaults = .standard,
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault()
    ) {
        [
            modeKey, kindKey, hostKey, portKey, usernameKey,
            legacyModeKey, legacyKindKey, legacyHostKey, legacyPortKey, legacyUsernameKey
        ].forEach {
            defaults.removeObject(forKey: $0)
        }
        keychain.delete(key: passwordAccount, service: passwordService)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    @MainActor
    @discardableResult
    static func applyStored(
        defaults: UserDefaults = .standard,
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault()
    ) -> Result<TorUpstreamProxy?, OuterProxySettingsError> {
        let draft = loadDraft(defaults: defaults, keychain: keychain)
        let torProxy: TorUpstreamProxy?
        switch draft.mode {
        case .systemDefault:
            #if os(macOS)
            torProxy = systemStaticProxy()
            #else
            // VPNs and other system network routes operate below URLSession
            // and Arti on iOS, so no explicit upstream proxy is required.
            torProxy = nil
            #endif
            TorURLSession.shared.setOuterProxy(nil)
        case .custom:
            do {
                torProxy = try customProxy(from: draft)
                TorURLSession.shared.setOuterProxy(torProxy)
            } catch let error as OuterProxySettingsError {
                // A corrupt or temporarily inaccessible custom configuration must
                // fail closed instead of silently exposing direct relay traffic.
                let blocked = TorUpstreamProxy(kind: .httpConnect, host: "127.0.0.1", port: 1)
                TorURLSession.shared.setOuterProxy(blocked)
                TorManager.shared.setUpstreamProxy(blocked)
                return .failure(error)
            } catch {
                return .failure(.invalidHost)
            }
        }

        TorManager.shared.setUpstreamProxy(torProxy)
        return .success(torProxy)
    }

    static func customProxy(from draft: OuterProxyDraft) throws -> TorUpstreamProxy {
        let host = normalizedHost(draft.host)
        guard isValidHost(host), host.utf8.count <= maxFieldBytes else {
            throw OuterProxySettingsError.invalidHost
        }
        let portText = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(portText), port != 0 else {
            throw OuterProxySettingsError.invalidPort
        }
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = draft.password
        guard username.isEmpty == password.isEmpty else {
            throw OuterProxySettingsError.incompleteCredentials
        }
        guard username.utf8.count <= maxFieldBytes, password.utf8.count <= maxFieldBytes else {
            throw OuterProxySettingsError.oversizedCredentials
        }
        if draft.kind == .socks5,
           username.utf8.count > UInt8.max || password.utf8.count > UInt8.max {
            throw OuterProxySettingsError.oversizedCredentials
        }
        return TorUpstreamProxy(
            kind: draft.kind.torKind,
            host: host,
            port: port,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
    }

    #if os(macOS)
    static func systemStaticProxy(settings: [AnyHashable: Any]? = nil) -> TorUpstreamProxy? {
        let settings = settings ?? (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any])
        guard let settings else { return nil }

        if enabled(settings[kCFNetworkProxiesSOCKSEnable as String]),
           let proxy = proxy(
               kind: .socks5,
               host: settings[kCFNetworkProxiesSOCKSProxy as String],
               port: settings[kCFNetworkProxiesSOCKSPort as String]
           ) {
            return proxy
        }
        if enabled(settings[kCFNetworkProxiesHTTPSEnable as String]),
           let proxy = proxy(
               kind: .httpConnect,
               host: settings[kCFNetworkProxiesHTTPSProxy as String],
               port: settings[kCFNetworkProxiesHTTPSPort as String]
           ) {
            return proxy
        }
        if enabled(settings[kCFNetworkProxiesHTTPEnable as String]),
           let proxy = proxy(
               kind: .httpConnect,
               host: settings[kCFNetworkProxiesHTTPProxy as String],
               port: settings[kCFNetworkProxiesHTTPPort as String]
           ) {
            return proxy
        }
        return nil
    }

    static func systemProxyDescription() -> String? {
        guard let proxy = systemStaticProxy() else { return nil }
        let scheme = proxy.kind == .socks5 ? "SOCKS5" : "HTTP CONNECT"
        return "\(scheme) · \(proxy.host):\(proxy.port)"
    }

    private static func proxy(
        kind: TorUpstreamProxy.Kind,
        host: Any?,
        port: Any?
    ) -> TorUpstreamProxy? {
        guard let host = host as? String,
              isValidHost(host),
              let number = port as? NSNumber,
              (1...65_535).contains(number.intValue) else { return nil }
        return TorUpstreamProxy(kind: kind, host: host, port: UInt16(number.intValue))
    }

    private static func enabled(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue == true
    }
    #endif

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.contains(":") {
            var address = in6_addr()
            return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        return host.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !"/:?#[]@".unicodeScalars.contains(scalar)
        }
    }

    private static func normalizedHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }
}
