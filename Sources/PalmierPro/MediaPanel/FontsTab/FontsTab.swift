import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FontsTab: View {
    @State private var storedFonts: [(fileName: String, families: [String])] = []
    @State private var isTargeted = false
    @State private var errorMessage: String?

    private let fontTypes: [UTType] = [
        UTType(filenameExtension: "ttf") ?? .data,
        UTType(filenameExtension: "otf") ?? .data,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if storedFonts.isEmpty {
                emptyState
            } else {
                fontList
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.medium)
                    .padding(AppTheme.Spacing.xs)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: fontTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear { reload() }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Fonts")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            Button {
                pickFontFile()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Import font (.ttf or .otf)")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "textformat")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("Drop .ttf or .otf files here")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Button("Import Font") { pickFontFile() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.xl)
    }

    private var fontList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(storedFonts, id: \.fileName) { font in
                    fontRow(font)
                    Divider().padding(.leading, AppTheme.Spacing.md)
                }
            }
        }
    }

    private func fontRow(_ font: (fileName: String, families: [String])) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "textformat.alt")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(font.families.joined(separator: ", "))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(font.fileName)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                removeFont(fileName: font.fileName)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove font")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private func pickFontFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = fontTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select .ttf or .otf font files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            doImport(path: url.path)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { doImport(path: url.path) }
            }
        }
        return true
    }

    private func doImport(path: String) {
        do {
            try FontStore.importFont(at: path)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeFont(fileName: String) {
        do {
            try FontStore.removeFont(fileName: fileName)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        storedFonts = FontStore.storedFonts
    }
}
