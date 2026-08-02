// SPDX-License-Identifier: MIT

import BitFoundation
import Foundation

enum ChatURLRoute: Equatable {
    case share
    case geohash(String)
    case user(PeerID)
    case verification(String)
}

/// Defines the URL schemes accepted by MeshChat without changing the
/// canonical scheme used by existing BitChat clients and shared links.
enum ChatURLScheme {
    static let canonical = "bitchat"
    static let meshChatAlias = "meshchat"

    static func accepts(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == canonical || scheme == meshChatAlias
    }

    /// Canonical parser shared by cold launch, Home, notifications, and
    /// mounted conversations. Keeping routing above the view tree prevents a
    /// deep link from becoming a no-op merely because a chat is not visible.
    static func route(for url: URL) -> ChatURLRoute? {
        guard accepts(url.scheme) else { return nil }

        switch url.host?.lowercased() {
        case "share":
            return .share

        case "geohash":
            let value = decodedPath(url).lowercased()
            let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
            guard (2...12).contains(value.count),
                  value.allSatisfy({ allowed.contains($0) }) else { return nil }
            return .geohash(value)

        case "user":
            let value = decodedPath(url)
            guard !value.isEmpty else { return nil }
            return .user(PeerID(str: value))

        case "verify":
            // Signature, freshness, and peer matching remain the verification
            // subsystem's job. Routing retains the exact signed URL bytes.
            return .verification(url.absoluteString)

        default:
            return nil
        }
    }

    private static func decodedPath(_ url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.removingPercentEncoding ?? path
    }
}
