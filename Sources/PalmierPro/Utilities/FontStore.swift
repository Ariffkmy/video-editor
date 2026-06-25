import AppKit
import CoreText
import Foundation

enum FontStoreError: LocalizedError {
    case notFound(String), unsupportedFormat(String), invalidFont(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let p):        "No file at path: \(p)"
        case .unsupportedFormat(let e): "Unsupported format '.\(e)' — use .ttf or .otf"
        case .invalidFont(let name):  "'\(name)' could not be read as a font"
        }
    }
}

/// Global font library stored in Application Support. Fonts here are available in every project.
enum FontStore {
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/fonts", isDirectory: true)

    /// Registers all previously imported fonts and returns their family names.
    /// Call once at launch alongside BundledFonts.register().
    @MainActor
    static func registerAll() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var urls: [URL] = []
        var families = Set<String>()
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }
            urls.append(url)
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                for d in descs {
                    if let f = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                        families.insert(f)
                    }
                }
            }
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { _, _ in true }
        BundledFonts.setImportedFamilies(Array(families))
    }

    /// Copies a font file into the global store, registers it for the current session,
    /// and returns the family names it provides.
    @MainActor
    static func importFont(at path: String) throws -> [String] {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FontStoreError.notFound(source.path)
        }
        let ext = source.pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" else {
            throw FontStoreError.unsupportedFormat(source.pathExtension)
        }
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(source as CFURL) as? [CTFontDescriptor],
              !descs.isEmpty else {
            throw FontStoreError.invalidFont(source.lastPathComponent)
        }
        let families = Array(Set(descs.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        })).sorted()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL != dest.standardizedFileURL {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        }

        CTFontManagerRegisterFontURLs([dest] as CFArray, .process, true) { _, _ in true }
        BundledFonts.addImportedFamilies(families)
        return families
    }

    /// Removes a stored font file and unregisters it.
    @MainActor
    static func removeFont(fileName: String) throws {
        let url = directory.appendingPathComponent(fileName)
        CTFontManagerUnregisterFontURLs([url] as CFArray, .process) { _, _ in true }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Rebuild the imported families list from what remains on disk.
        registerAll()
    }

    /// All font files in the store with their family names, sorted by family name.
    static var storedFonts: [(fileName: String, families: [String])] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(fileName: String, families: [String])] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }
            let families: [String]
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                families = Array(Set(descs.compactMap {
                    CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
                })).sorted()
            } else {
                families = [url.deletingPathExtension().lastPathComponent]
            }
            result.append((fileName: url.lastPathComponent, families: families))
        }
        return result.sorted { $0.families.first ?? "" < $1.families.first ?? "" }
    }
}
