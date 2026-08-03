#if os(macOS)
import CFNetwork
#endif
import XCTest
import Tor
@testable import bitchat

final class OuterProxySettingsTests: XCTestCase {
    func testCustomHTTPProxyValidation() throws {
        let proxy = try OuterProxySettings.customProxy(
            from: OuterProxyDraft(
                mode: .custom,
                kind: .httpConnect,
                host: "proxy.example",
                port: "8443",
                username: "alice",
                password: "secret"
            )
        )

        XCTAssertEqual(proxy.kind, .httpConnect)
        XCTAssertEqual(proxy.host, "proxy.example")
        XCTAssertEqual(proxy.port, 8443)
        XCTAssertEqual(proxy.username, "alice")
        XCTAssertEqual(proxy.password, "secret")
    }

    func testCustomProxyRejectsURLInsteadOfHost() {
        XCTAssertThrowsError(
            try OuterProxySettings.customProxy(
                from: OuterProxyDraft(
                    mode: .custom,
                    kind: .socks5,
                    host: "socks5://127.0.0.1",
                    port: "1080",
                    username: "",
                    password: ""
                )
            )
        ) { error in
            XCTAssertEqual(error as? OuterProxySettingsError, .invalidHost)
        }
    }

    func testCustomProxyRejectsIncompleteCredentials() {
        XCTAssertThrowsError(
            try OuterProxySettings.customProxy(
                from: OuterProxyDraft(
                    mode: .custom,
                    kind: .httpConnect,
                    host: "127.0.0.1",
                    port: "8080",
                    username: "alice",
                    password: ""
                )
            )
        ) { error in
            XCTAssertEqual(error as? OuterProxySettingsError, .incompleteCredentials)
        }
    }

    func testCustomProxyAcceptsBracketedIPv6Host() throws {
        let proxy = try OuterProxySettings.customProxy(
            from: OuterProxyDraft(
                mode: .custom,
                kind: .socks5,
                host: "[::1]",
                port: "1080",
                username: "",
                password: ""
            )
        )

        XCTAssertEqual(proxy.host, "::1")
    }

    func testSOCKSProxyRejectsCredentialsOverProtocolLimit() {
        XCTAssertThrowsError(
            try OuterProxySettings.customProxy(
                from: OuterProxyDraft(
                    mode: .custom,
                    kind: .socks5,
                    host: "127.0.0.1",
                    port: "1080",
                    username: String(repeating: "x", count: 256),
                    password: "secret"
                )
            )
        ) { error in
            XCTAssertEqual(error as? OuterProxySettingsError, .oversizedCredentials)
        }
    }

    #if os(macOS)
    func testSystemProxyPrefersSOCKSOverHTTP() {
        let settings: [AnyHashable: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: 1080,
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "http.example",
            kCFNetworkProxiesHTTPPort as String: 8080
        ]

        let proxy = OuterProxySettings.systemStaticProxy(settings: settings)

        XCTAssertEqual(proxy?.kind, .socks5)
        XCTAssertEqual(proxy?.host, "127.0.0.1")
        XCTAssertEqual(proxy?.port, 1080)
    }
    #endif

    func testCustomProxyRoundTripsPasswordThroughKeychain() throws {
        let suite = "OuterProxySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = PreviewKeychainManager()
        let draft = OuterProxyDraft(
            mode: .custom,
            kind: .socks5,
            host: "localhost",
            port: "1080",
            username: "alice",
            password: "secret"
        )

        guard case .success = OuterProxySettings.save(
            draft,
            defaults: defaults,
            keychain: keychain
        ) else {
            return XCTFail("Expected proxy settings to save")
        }

        XCTAssertEqual(
            OuterProxySettings.loadDraft(defaults: defaults, keychain: keychain),
            draft
        )
    }

    func testResetRemovesProxyConfigurationAndPassword() throws {
        let suite = "OuterProxySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = PreviewKeychainManager()
        let draft = OuterProxyDraft(
            mode: .custom,
            kind: .socks5,
            host: "localhost",
            port: "1080",
            username: "alice",
            password: "secret"
        )
        guard case .success = OuterProxySettings.save(
            draft,
            defaults: defaults,
            keychain: keychain
        ) else {
            return XCTFail("Expected proxy settings to save")
        }

        OuterProxySettings.reset(defaults: defaults, keychain: keychain)

        XCTAssertEqual(
            OuterProxySettings.loadDraft(defaults: defaults, keychain: keychain),
            OuterProxyDraft(
                mode: .systemDefault,
                kind: .httpConnect,
                host: "",
                port: "",
                username: "",
                password: ""
            )
        )
    }

    func testCustomProxyConfiguresDirectRelaySession() throws {
        let proxy = TorUpstreamProxy(
            kind: .httpConnect,
            host: "proxy.example",
            port: 8443,
            username: "alice",
            password: "secret"
        )
        defer {
            TorURLSession.shared.setOuterProxy(nil)
            TorURLSession.shared.setProxyMode(useTor: true)
        }

        TorURLSession.shared.setOuterProxy(proxy)
        TorURLSession.shared.setProxyMode(useTor: false)

        let settings = try XCTUnwrap(
            TorURLSession.shared.session.configuration.connectionProxyDictionary
        )
        XCTAssertEqual(settings["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(settings["HTTPProxy"] as? String, "proxy.example")
        XCTAssertEqual(settings["HTTPPort"] as? Int, 8443)
        XCTAssertEqual(settings["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(settings["HTTPSProxy"] as? String, "proxy.example")
        XCTAssertEqual(settings["HTTPSPort"] as? Int, 8443)
        XCTAssertEqual(settings["kCFProxyUsernameKey"] as? String, "alice")
        XCTAssertEqual(settings["kCFProxyPasswordKey"] as? String, "secret")
    }
}
