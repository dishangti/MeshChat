<img width="256" height="256" alt="MeshChat app icon" src="bitchat/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png" />

## MeshChat

MeshChat is a native Swift, conversation-first messaging app for iOS, iPadOS,
and macOS. It is a protocol- and security-compatible superset of BitChat: local
Bluetooth mesh networks provide offline communication, while Nostr provides
optional global reach. There are no accounts, phone numbers, or central
messaging servers.

Existing BitChat wire identifiers, cryptographic protocol contexts, and
canonical `bitchat://` links remain unchanged so MeshChat can communicate with
existing clients. The app also accepts `meshchat://` links as a local alias.

[BitChat protocol site](http://bitchat.free)

Compatible clients: [BitChat for Apple platforms](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)
and [BitChat for Android](https://play.google.com/store/apps/details?id=com.bitchat.droid).

### Getting a copy you can trust

Build MeshChat from source you have verified. A compiled build from anywhere
else cannot be verified — see [Verifying a build](docs/VERIFYING-A-BUILD.md) for
how to check source against a per-release hash manifest, and for what to do if
that is the only build you can get.

This matters more than it usually would: this repository has been the target of takedown demands, and when a repository or releases page disappears, mirrors appear that nobody can check.

## License

This project is licensed under the [MIT License](LICENSE). Third-party dependencies and vendored components remain subject to their respective licenses.

## Features

- **Dual Transport Architecture**: Bluetooth mesh for offline + Nostr protocol for internet-based messaging
- **Conversation-First Interface**: Adaptive sidebar and chat layout inspired by familiar IM apps
- **Responsive Navigation**: Compact navigation on iPhone and persistent split views on iPad and Mac
- **Conversation Drafts**: Separate unsent drafts for mesh, location, private, and group conversations
- **Location-Based Channels**: Geographic chat rooms using geohash coordinates over global Nostr relays
- **Intelligent Message Routing**: Automatically chooses best transport (Bluetooth → Nostr fallback)
- **Decentralized Mesh Network**: Automatic peer discovery and multi-hop message relay over Bluetooth LE
- **Privacy First**: No accounts, no phone numbers, no servers. Note that the mesh does use a persistent per-device identifier derived from your identity key — see [the whitepaper](WHITEPAPER.md) on identity and metadata for what a nearby radio can observe
- **Private Message End-to-End Encryption**: [Noise Protocol](https://noiseprotocol.org) for mesh, BitChat private envelopes for Nostr fallback
- **IRC-Style Commands**: Familiar `/slap`, `/msg`, `/who` style interface
- **Universal App**: Native support for iOS, iPadOS, and macOS
- **Emergency Wipe**: Triple-tap to instantly clear all data
- **Performance Optimizations**: LZ4 message compression, adaptive battery modes, and optimized networking

## [Technical Architecture](https://deepwiki.com/permissionlesstech/bitchat)

MeshChat retains BitChat's **hybrid messaging architecture** with two complementary transport layers:

### Bluetooth Mesh Network (Offline)

- **Local Communication**: Direct peer-to-peer within Bluetooth range
- **Multi-hop Relay**: Messages route through nearby devices (max 7 hops)
- **No Internet Required**: Works completely offline in disaster scenarios
- **Noise Protocol Encryption**: End-to-end encryption, with forward secrecy for live sessions (store-and-forward mail is sealed without it — see the whitepaper)
- **Binary Protocol**: Compact packet format optimized for Bluetooth LE constraints
- **Automatic Discovery**: Peer discovery and connection management
- **Adaptive Power**: Battery-optimized duty cycling

### Nostr Protocol (Internet)

- **Global Reach**: Connect with users worldwide via internet relays
- **Location Channels**: Geographic chat rooms using geohash coordinates
- **440+ Relay Network**: Distributed across the globe for reliability
- **BitChat Private Envelopes**: App-specific encrypted private messages over Nostr relays
- **Ephemeral Keys**: Fresh cryptographic identity per geohash area

BitChat's private-envelope format is proprietary and is **not** NIP-17,
NIP-44, or NIP-59 compatible. It uses Nostr as a relay transport but only
interoperates with BitChat clients: private payloads travel inside kind-1059
events whose `v2:`-prefixed content is a BitChat-specific XChaCha20-Poly1305
construction, not NIP-44 encryption.

### Channel Types

#### `mesh #bluetooth`

- **Transport**: Bluetooth Low Energy mesh network
- **Scope**: Local devices within multi-hop range
- **Internet**: Not required
- **Use Case**: Offline communication, protests, disasters, remote areas

#### Location Channels (`block #dr5rsj7`, `neighborhood #dr5rs`, `country #dr`)

- **Transport**: Nostr protocol over internet
- **Scope**: Geographic areas defined by geohash precision
  - `block` (7 chars): City block level
  - `neighborhood` (6 chars): District/neighborhood
  - `city` (5 chars): City level
  - `province` (4 chars): State/province
  - `region` (2 chars): Country/large region
- **Internet**: Required (connects to Nostr relays)
- **Use Case**: Location-based community chat, local events, regional discussions

### Direct Message Routing

Private messages use **intelligent transport selection**:

1. **Bluetooth First** (preferred when available)

   - Direct connection with established Noise session
   - Fastest and most private option

2. **Nostr Fallback** (when Bluetooth unavailable)

   - Uses recipient's Nostr public key
   - BitChat's app-specific private-envelope encryption
   - Routes through global relay network

3. **Smart Queuing** (when neither available)
   - Messages queued until transport becomes available
   - Automatic delivery when connection established

For detailed protocol documentation, see the [Technical Whitepaper](WHITEPAPER.md).

## Setup

The built products are `MeshChat.app` and `MeshChatShareExtension.appex`. Bundle
and App Group identifiers include the configured Apple Developer Team ID; the
tracked default resolves to `chat.meshchat.F9LRFWZSBW` and
`group.chat.meshchat.F9LRFWZSBW`. The Xcode target names and Swift module remain
`bitchat` so source-level protocol types and test imports stay stable. Canonical
BitChat wire identifiers and `bitchat://` links are also retained for
interoperability. The new Bundle Identifier intentionally gives MeshChat its
own app container and default Keychain access group; it does not silently
inherit data from an installed BitChat build.

Debug and Release builds both use BitChat's canonical mainnet BLE service UUID
so a normal Xcode Run can discover released BitChat clients. Developers who
need an isolated radio test network can opt in with the
`BITCHAT_BLE_TESTNET` Swift compilation condition.

### Option 1: Using Xcode

```bash
open bitchat.xcodeproj
```

For a signed device build, create your ignored local configuration and replace
the example team ID with your Apple Developer Team ID:

```bash
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
```

`Local.xcconfig.example` derives unique app and App Group identifiers from that
team ID. The entitlement files already reference `$(APP_GROUP_ID)`, so tracked
project or entitlement files do not need to be edited.

Useful command-line checks from the repository root:

```bash
# macOS Debug build without signing
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Full SwiftPM test suite
swift test

# iOS simulator tests
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

If `iPhone 17` is unavailable, choose an installed simulator from:

```bash
xcodebuild -showdestinations -project bitchat.xcodeproj -scheme "bitchat (iOS)"
```

### Option 2: Using `just`

```bash
brew install just
just check
just run
```

`just build` and `just run` use the current `bitchat (macOS)` scheme and keep
Xcode output in the ignored `.DerivedData/` directory. They never patch source,
project, configuration, or entitlement files.

`just clean` removes only `.DerivedData/` and `.build/`. It does not invoke Git
or restore tracked files, so uncommitted work is preserved. `just test` runs the
SwiftPM suite and `just test-ios` runs the iPhone 17 simulator suite.

## Localization

- App localizations live in `bitchat/Localizable.xcstrings`.
- Share extension strings are separate in `bitchatShareExtension/Localization/Localizable.xcstrings`.
- Prefer keys that describe intent (`app_info.features.offline.title`) and reuse existing ones where possible.
- Run `xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build` to compile-check any localization updates.
