import Foundation

/// Provides a shared URLSession that routes traffic via Tor's SOCKS5 proxy
/// when Tor is enforced/ready. Allows swapping between proxied and direct
/// sessions so UI can toggle Tor usage at runtime.
public final class TorURLSession {
    public static let shared = TorURLSession()

    // Default (no proxy) session for direct Nostr access when Tor is disabled.
    private var defaultSession: URLSession = TorURLSession.makeDefaultSession()

    // Proxied (SOCKS5) session that routes through Tor.
    private var torSession: URLSession = TorURLSession.makeTorSession()
    private var useTorProxy: Bool = true
    private var outerProxy: TorUpstreamProxy?

    public var session: URLSession {
        useTorProxy ? torSession : defaultSession
    }

    // Recreate sessions so new clients bind to the fresh SOCKS/control ports after a Tor restart.
    public func rebuild() {
        defaultSession = TorURLSession.makeDefaultSession(outerProxy: outerProxy)
        torSession = TorURLSession.makeTorSession()
    }

    /// Nil follows the operating system's default proxy configuration. A value
    /// explicitly overrides it for direct relay connections; Tor applies the same
    /// value inside `TorManager` before connecting to its first hop.
    public func setOuterProxy(_ proxy: TorUpstreamProxy?) {
        guard outerProxy != proxy else { return }
        outerProxy = proxy
        rebuild()
    }

    public func setProxyMode(useTor: Bool) {
        guard useTorProxy != useTor else { return }
        useTorProxy = useTor
        rebuild()
    }

    private static func makeTorSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        // Keep in sync with TorManager defaults
        let host = "127.0.0.1"
        let port = 39050
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port
        ]
        return URLSession(configuration: cfg)
    }

    private static func makeDefaultSession(outerProxy: TorUpstreamProxy? = nil) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        if let proxy = outerProxy {
            var settings: [AnyHashable: Any]
            switch proxy.kind {
            case .socks5:
                settings = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": Int(proxy.port)
                ]
            case .httpConnect:
                settings = [
                    "HTTPEnable": 1,
                    "HTTPProxy": proxy.host,
                    "HTTPPort": Int(proxy.port),
                    "HTTPSEnable": 1,
                    "HTTPSProxy": proxy.host,
                    "HTTPSPort": Int(proxy.port)
                ]
            }
            if let username = proxy.username, let password = proxy.password {
                settings["kCFProxyUsernameKey"] = username
                settings["kCFProxyPasswordKey"] = password
            }
            cfg.connectionProxyDictionary = settings
        }
        return URLSession(configuration: cfg)
    }
}
