// Port of `packages/diffs/src/utils/getFiletypeFromFileName.ts`.

import Foundation

/// Maps file names to syntax highlighting languages.
public enum FileTypes {
    private final class CustomExtensions: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: SupportedLanguage] = [:]
        var version = 0
    }

    private static let custom = CustomExtensions()

    /// Returns the language for a file name (`text` when unknown).
    public static func getFiletypeFromFileName(_ fileName: String) -> SupportedLanguage {
        let customMap = custom.lock.withLock { custom.map }
        if let language = customMap[fileName] {
            return language
        }
        // Handle special files without extensions first
        if let language = extensionToFileFormat[fileName] {
            return language
        }
        // Try compound extensions first (e.g., .blade.php, .component.ts)
        if let compound = compoundExtension(fileName) {
            if let language = customMap[compound] { return language }
            if let language = extensionToFileFormat[compound] { return language }
        }
        // Fall back to simple extension
        let simple = simpleExtension(fileName) ?? ""
        if let language = customMap[simple] { return language }
        return extensionToFileFormat[simple] ?? "text"
    }

    /// Equivalent of `fileName.match(/\.([^/\\]+\.[^/\\]+)$/)?.[1]`.
    static func compoundExtension(_ fileName: String) -> String? {
        let units = Array(fileName.utf16)
        let isSlash: (UInt16) -> Bool = { $0 == 0x2F || $0 == 0x5C }
        // The match cannot span a slash, so only dots after the last slash
        // qualify; the leftmost qualifying dot wins.
        let lastSlash = units.lastIndex(where: isSlash) ?? -1
        var i = lastSlash + 1
        while i < units.count {
            if units[i] == 0x2E {
                let rest = units[(i + 1)...]
                // Needs `x.y` with non-empty parts around some inner dot.
                if let inner = rest.dropFirst().dropLast().firstIndex(of: 0x2E), inner > i + 1 {
                    return String(decoding: rest, as: UTF16.self)
                }
            }
            i += 1
        }
        return nil
    }

    /// Equivalent of `fileName.match(/\.([^.]+)$/)?.[1]`.
    static func simpleExtension(_ fileName: String) -> String? {
        let units = Array(fileName.utf16)
        guard let lastDot = units.lastIndex(of: 0x2E), lastDot + 1 < units.count else { return nil }
        return String(decoding: units[(lastDot + 1)...], as: UTF16.self)
    }

    /// Maps a file name or extension (without the dot) to a language.
    @discardableResult
    public static func setCustomExtension(_ key: String, _ language: SupportedLanguage) -> Bool {
        custom.lock.withLock {
            if custom.map[key] == language { return false }
            custom.map[key] = language
            custom.version += 1
            return true
        }
    }

    /// Replaces all custom mappings when `version` is newer than the current
    /// one.
    @discardableResult
    public static func replaceCustomExtensions(version: Int, _ map: [String: SupportedLanguage]) -> Bool {
        custom.lock.withLock {
            if version <= custom.version { return false }
            custom.map = map
            custom.version = version
            return true
        }
    }

    public static var customExtensionsVersion: Int {
        custom.lock.withLock { custom.version }
    }

    public static var customExtensionsMap: [String: SupportedLanguage] {
        custom.lock.withLock { custom.map }
    }
}

/// Port of `getFiletypeFromFileName`.
public func getFiletypeFromFileName(_ fileName: String) -> SupportedLanguage {
    FileTypes.getFiletypeFromFileName(fileName)
}
