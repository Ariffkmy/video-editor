import Foundation

extension ToolExecutor {
    func importFont(_ args: [String: Any]) throws -> ToolResult {
        guard let path = args.string("path") else {
            throw ToolError("import_font: missing required argument 'path'")
        }
        let families: [String]
        do {
            families = try FontStore.importFont(at: path)
        } catch let e as FontStoreError {
            throw ToolError("import_font: \(e.localizedDescription ?? e.errorDescription ?? "failed")")
        }
        guard let json = Self.jsonString([
            "imported": families,
            "note": "Font is now available in the font picker under 'Imported'. Use the family name exactly as returned when calling add_texts or set_clip_properties.",
        ]) else { throw ToolError("import_font: failed to encode result") }
        return .ok(json)
    }
}
