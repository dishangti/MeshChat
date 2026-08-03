# Arti Binary Provenance

This repo vendors a prebuilt Arti static-library xcframework at:

`localPackages/Arti/Frameworks/arti.xcframework`

SwiftPM links it through `localPackages/Arti/Package.swift` as the binary target named `arti`. Treat changes to this artifact like dependency updates: review the Rust sources, lockfile, build script, produced headers, and artifact hashes together.

## Source Inputs

- Rust workspace: `localPackages/Arti/Cargo.toml`
- Crate: `localPackages/Arti/arti-bitchat`
- Dependency lockfile: `localPackages/Arti/Cargo.lock`
- Build script: `localPackages/Arti/build-ios.sh`
- Exported C header: `localPackages/Arti/Frameworks/include/arti.h`

The crate declares `rust-version = "1.90"` and uses `arti-client` / `tor-rtcompat` `0.38` with minimal Tokio/Rustls features. The current lockfile requires Rust 1.90 or newer. The build script currently targets:

- `aarch64-apple-ios`
- `aarch64-apple-ios-sim`
- `x86_64-apple-ios`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

It builds release static libraries with size-oriented flags (`opt-level=z`, fat LTO, one codegen unit, `panic=abort`, stripped symbols), normalizes static-archive metadata with `xcrun libtool -static -D`, then packages them with `xcodebuild -create-xcframework`.

## Regenerating The Artifact

From the repo root:

```sh
cd localPackages/Arti
rustup toolchain install 1.96.0
rustup target add --toolchain 1.96.0 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
rustup run 1.96.0 cargo install cbindgen --version 0.29.4 --locked
./build-ios.sh
```

`build-ios.sh` defaults to the audited `1.96.0` toolchain and refuses a rustc
version other than `1.96.0`; it likewise requires cbindgen `0.29.4`. Set
`RUST_TOOLCHAIN`, `RUSTC_VERSION`, or `CBINDGEN_VERSION` explicitly only when
intentionally updating the binary provenance and hashes below.

After rebuilding, verify that:

- `Cargo.lock` changes are intentional and reviewed.
- `Frameworks/include/arti.h` still matches the exported FFI functions used by `TorManager`.
- `Frameworks/arti.xcframework` contains iOS device arm64, universal iOS simulator arm64+x86_64, and universal macOS arm64+x86_64 slices.
- The main app still passes iOS tests and the macOS build.

## Audited Rebuild

The July 2026 artifact below was rebuilt from source on this host with:

```text
rustc 1.96.0 (ac68faa20 2026-05-25)
cargo 1.96.0 (30a34c682 2026-05-25)
rustup 1.29.0 (28d1352db 2026-03-05)
cbindgen 0.29.4
Xcode 26.6
Build version 17F113
```

Rust 1.86.0 was also checked during the audit and no longer builds this lockfile because `typed-index-collections@3.4.0` requires Rust 1.90.0 or newer.

The build script now normalizes static-archive metadata and writes a stable xcframework `Info.plist`. Two consecutive no-source-change rebuilds on this host produced the same hashes below.

## Current Artifact Hashes

Run this from the repo root to verify the checked-in artifact:

```sh
find localPackages/Arti/Frameworks/arti.xcframework -maxdepth 3 -type f -print0 | sort -z | xargs -0 shasum -a 256
```

Current hashes:

```text
cac99db408280bbef15cae8ce64c8ccdbf2e8863c205168d59f83fe8ab680f94  localPackages/Arti/Frameworks/arti.xcframework/Info.plist
e338cfc248144da947262da419795f21bfaf86c223dab39845ada932e87f1dbc  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/Headers/arti.h
fb5c427b37c18b8a0020728d159dd3e47557fd9821151460f986e83f32fa844b  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/libarti_bitchat.a
e338cfc248144da947262da419795f21bfaf86c223dab39845ada932e87f1dbc  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/Headers/arti.h
eb4c699f98b93109057a6ead3198824ff2dc989f46bbb817618ec366a3ed6bbf  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/libarti_bitchat.a
e338cfc248144da947262da419795f21bfaf86c223dab39845ada932e87f1dbc  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/Headers/arti.h
f7d9b87bc69374a108eb9d5fa80559a6e0175f3d8bad05948801a20ca0dfdd0e  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/libarti_bitchat.a
```

## Review Checklist

- Record `rustc --version`, `cargo --version`, `cbindgen --version`, and `xcodebuild -version` in the PR when refreshing the binary.
- Include the hash output above after any binary change.
- If a rebuild changes only xcframework/library bytes, record the new hashes and app validation evidence in the PR.
- Keep `target/`, `.build/`, and `.swiftpm/` out of source control.
- Do not accept an xcframework-only update without matching source, lockfile, or build-script evidence explaining where it came from.
