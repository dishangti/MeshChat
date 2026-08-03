import Foundation

/// An outer proxy used before either a direct relay connection or the first Tor hop.
public struct TorUpstreamProxy: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case socks5
        case httpConnect

        fileprivate var ffiValue: UInt8 {
            switch self {
            case .socks5: return 1
            case .httpConnect: return 2
            }
        }
    }

    public let kind: Kind
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?

    public init(
        kind: Kind,
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

extension TorUpstreamProxy.Kind {
    var artiFFIValue: UInt8 { ffiValue }
}
