import Foundation

/// In-app override for the UI language, on top of the system per-app language.
/// SwiftUI receives the matching locale, while strings needed outside a view
/// are resolved from the selected localization bundle directly.
enum AppLanguageSettings {
    /// "" means no override: follow the device (or per-app system) language.
    static let overrideKey = "app.languageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    /// Reads the device-wide language order without the app-local
    /// `AppleLanguages` value written by older MeshChat versions.
    private static var systemPreferredLanguages: [String] {
        let defaults = UserDefaults.standard
        let globalDomains = [
            defaults.persistentDomain(forName: UserDefaults.globalDomain),
            defaults.volatileDomain(forName: UserDefaults.globalDomain)
        ]

        for domain in globalDomains {
            if let languages = domain?[appleLanguagesKey] as? [String],
               !languages.isEmpty {
                return languages
            }
        }
        return Locale.preferredLanguages
    }

    /// Localization bundles are immutable and safe to share across calls from
    /// views, notifications, and transport callbacks.
    private static let bundlesByLanguage: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: Bundle.main.localizations.compactMap { code in
            guard code != "Base",
                  let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return nil
            }
            return (code, bundle)
        })
    }()

    /// Language codes the app ships translations for, straight from the
    /// built bundle so this never drifts from the string catalog.
    static var availableLanguages: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { endonym(for: $0).localizedCaseInsensitiveCompare(endonym(for: $1)) == .orderedAscending }
    }

    /// The language's name in that language ("فارسی", "한국어") so every user
    /// can find their own entry regardless of the current UI language.
    static func endonym(for code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        guard let first = name.first else { return name }
        return String(first).uppercased(with: locale) + name.dropFirst()
    }

    /// Locale injected at the app root so `Text` and every
    /// `LocalizedStringKey` update as soon as the setting changes.
    static func locale(for code: String) -> Locale {
        Locale(identifier: code.isEmpty ? systemLanguageCode : code)
    }

    /// The best shipped localization for the real system language order.
    static var systemLanguageCode: String {
        preferredSupportedLanguage(
            for: systemPreferredLanguages,
            supportedLanguages: availableLanguages
        ) ?? "en"
    }

    /// Uses Foundation's locale matching so regional identifiers such as
    /// `en-US` and `zh-Hans-US` resolve to the shipped `en` and `zh-Hans`
    /// localization bundles.
    static func preferredSupportedLanguage(
        for preferences: [String],
        supportedLanguages: [String]
    ) -> String? {
        Bundle.preferredLocalizations(
            from: supportedLanguages,
            forPreferences: preferences
        ).first
    }

    /// Resolves a plain string using the in-app override. This mirrors the
    /// Foundation localization API used by MeshChat and also covers strings
    /// produced outside SwiftUI, such as notifications and delivery errors.
    static func localized(
        _ key: String,
        defaultValue: String? = nil,
        comment: StaticString? = nil
    ) -> String {
        _ = comment
        let code = UserDefaults.standard.string(forKey: overrideKey) ?? ""
        let effectiveCode = code.isEmpty ? systemLanguageCode : code
        let bundle = bundlesByLanguage[effectiveCode] ?? Bundle.main
        return bundle.localizedString(
            forKey: key,
            value: defaultValue,
            table: "Localizable"
        )
    }

    /// Removes the app-local language value written by older MeshChat builds
    /// when it matches the in-app override that those builds persisted.
    static func migrateLegacyAppleLanguagesOverride(
        defaults: UserDefaults = .standard
    ) {
        guard let override = defaults.string(forKey: overrideKey),
              !override.isEmpty,
              defaults.stringArray(forKey: appleLanguagesKey)?.first == override else {
            return
        }
        defaults.removeObject(forKey: appleLanguagesKey)
    }

    /// Persists the MeshChat override without mutating Foundation's system
    /// language preference. Nil immediately restores the real system locale.
    static func setOverride(
        _ code: String?,
        defaults: UserDefaults = .standard
    ) {
        migrateLegacyAppleLanguagesOverride(defaults: defaults)
        if let code, !code.isEmpty {
            defaults.set(code, forKey: overrideKey)
        } else {
            defaults.removeObject(forKey: overrideKey)
        }
    }
}
