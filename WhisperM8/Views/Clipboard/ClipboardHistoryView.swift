import AppKit
import SwiftUI

// MARK: - Verlaufs-Fenster

/// Suchfeld, Liste (Angepinnte oben), Vorschau und Tastenhinweise.
/// Tasten laufen über das Panel (`ClipboardPanel`), nicht über SwiftUI: so
/// bleibt das Suchfeld für Text zuständig und die Befehle sind fensterweit gleich.
struct ClipboardHistoryView: View {
    /// Feste Größe des Panels (passt auch auf ein 13-Zoll-MacBook).
    static let size = CGSize(width: 940, height: 580)
    static let listWidth: CGFloat = 390

    @ObservedObject var model: ClipboardHistoryViewModel
    @FocusState private var searchFocused: Bool
    var now: Date = Date()

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            searchBar(count: list.count)
            Divider().overlay(AppTheme.border)
            if model.showsSelectionHeader {
                selectionHeader
                Divider().overlay(AppTheme.border)
            }
            HStack(spacing: 0) {
                listColumn(list)
                    .frame(width: Self.listWidth)
                Divider().overlay(AppTheme.border)
                previewColumn
            }
            Divider().overlay(AppTheme.border)
            shortcutBar
        }
        .overlay {
            if model.isZoomed, let entry = model.selectedEntry {
                zoomOverlay(entry)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(AppTheme.panel)
        .onAppear { searchFocused = true }
    }

    // MARK: Suche

    private func searchBar(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textTertiary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            filterPicker
            Text("Items: \(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// Alles oder nur Diktate (⌘D). Zwei sichtbare Knöpfe, kein Menü.
    private var filterPicker: some View {
        HStack(spacing: 2) {
            filterButton(.all) { Text("All") }
            filterButton(.dictations) {
                HStack(spacing: 3) {
                    Image(systemName: "mic.fill").font(.system(size: 10))
                    Text("Dictations")
                }
            }
        }
        .padding(2)
        .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(String(localized: "Show only dictations (⌘D)"))
    }

    private func filterButton(_ filter: ClipboardHistoryViewModel.Filter, @ViewBuilder label: () -> some View) -> some View {
        let active = model.filter == filter
        return Button { model.filter = filter } label: {
            label()
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AppTheme.textPrimary : AppTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .fixedSize()
                .background(active ? AppTheme.panel : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Markierung

    /// Kopfzeile, wenn in der App davor Text markiert ist (oder die App es
    /// nicht verrät): ein Klick korrigiert die Markierung dort, wie ⇧⌘K.
    private var selectionHeader: some View {
        let app = model.selectionAppName ?? String(localized: "the app")
        return HStack(spacing: 10) {
            Image(systemName: "text.cursor")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if case .selected(let preview) = model.selectionProbe {
                    Text("Selected in \(app)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(verbatim: "“\(preview)”")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text("Text selected in \(app)?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("WhisperM8 can't see it from here. Click and it gets copied and corrected.")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Correct Selection") { model.actions.correctSelection() }
                .buttonStyle(SettingsButtonStyle.primary)
                .fixedSize()
                .help(correctSelectionHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(AppTheme.accentTint)
    }

    private var correctSelectionHelp: String {
        if let shortcut = model.correctShortcutLabel {
            return String(localized: "Fix spelling and grammar of the selection and replace it (\(shortcut))")
        }
        return String(localized: "Fix spelling and grammar of the selection and replace it")
    }

    // MARK: Liste

    @ViewBuilder
    private func listColumn(_ list: [ClipboardEntry]) -> some View {
        if list.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 24))
                    .foregroundStyle(AppTheme.textTertiary)
                if model.isSearching {
                    Text("Nothing found").font(.system(size: 13, weight: .medium))
                } else if model.filter == .dictations {
                    Text("No dictations yet").font(.system(size: 13, weight: .medium))
                    Text("Finished dictations show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text("No clipboard history yet").font(.system(size: 13, weight: .medium))
                    Text("Copy something and it shows up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(AppTheme.textPrimary)
        } else {
            // Nummern zählen genau in der gezeigten Reihenfolge (wie ⌘1 bis ⌘9).
            let numbered = Array(list.enumerated())
            let pinnedCount = model.showsPinnedGroup ? list.prefix { $0.isPinned }.count : 0
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if pinnedCount > 0 {
                            groupHeader("Pinned")
                            ForEach(numbered.prefix(pinnedCount), id: \.element.id) { index, entry in
                                row(entry, number: index + 1)
                            }
                            if pinnedCount < list.count { groupHeader("History") }
                        }
                        ForEach(numbered.dropFirst(pinnedCount), id: \.element.id) { index, entry in
                            row(entry, number: index + 1)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func groupHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(AppTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func row(_ entry: ClipboardEntry, number: Int) -> some View {
        let selected = entry.id == model.selectedID
        return HStack(spacing: 8) {
            leadingIcon(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(for: entry))
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: subtitle(for: entry))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            Spacer(minLength: 4)
            if entry.kind == .image, let image = model.thumbnails[entry.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if number <= 9 {
                Text(verbatim: "⌘\(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            Button {
                model.actions.togglePin(entry)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isPinned ? AppTheme.statusAwaiting : AppTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(entry.isPinned ? String(localized: "Unpin") : String(localized: "Pin"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? AppTheme.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.actions.paste(entry, false) }
        .onTapGesture { model.select(entry.id) }
        .id(entry.id)
    }

    @ViewBuilder
    private func leadingIcon(_ entry: ClipboardEntry) -> some View {
        if entry.dictationMode != nil {
            // Diktat-Ergebnisse erkennt man am Mikrofon, nicht am Ziel-App-Icon.
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22, height: 22)
                .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let icon = model.appIcon(for: entry) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: symbol(for: entry.kind))
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func symbol(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    /// Zeilentitel. Bilder heißen im Index „Image B × H“ (auch für Suche und
    /// CLI); angezeigt wird der Titel in der Sprache der App.
    static func title(for entry: ClipboardEntry) -> String {
        if entry.kind == .image {
            if let w = entry.imageWidth, let h = entry.imageHeight { return String(localized: "Image \(w) × \(h)") }
            return String(localized: "Image")
        }
        return entry.preview.isEmpty ? " " : entry.preview
    }

    private func subtitle(for entry: ClipboardEntry) -> String {
        let time = ClipboardRelativeTime.string(from: entry.lastCopiedAt, now: now)
        var parts: [String] = []
        if let mode = entry.dictationMode { parts.append(String(localized: "Dictation (\(mode))")) }
        if let name = entry.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(time)
        return parts.joined(separator: " · ")
    }

    // MARK: Vorschau

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = model.selectedEntry {
                HStack {
                    kindTitle(entry.kind)
                    Spacer()
                    Text(verbatim: detail(for: entry))
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textTertiary)

                if entry.kind == .image {
                    if let image = model.previewImage {
                        // Klick vergrößert aufs ganze Fenster (wie ⌘Y).
                        Button { model.openZoom() } label: {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .padding(8)
                                }
                                .frame(maxWidth: .infinity, maxHeight: 380)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "View large (⌘Y)"))
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        Text(verbatim: model.previewText)
                            .font(ClipboardPreviewStyle.prefersMonospace(model.previewText)
                                  ? .system(size: 12.5, design: .monospaced)
                                  : .system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let original = entry.dictationOriginal {
                        originalSection(original)
                    }
                }
                actionRow(entry)
            } else {
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.surface)
    }

    /// Bild über das ganze Fenster. Enter fügt ein, Esc oder ⌘Y geht zurück,
    /// ↑ und ↓ blättern weiter durch die Liste.
    private func zoomOverlay(_ entry: ClipboardEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: Self.title(for: entry))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let name = entry.sourceName {
                    Text(verbatim: name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                Button("Paste") { model.actions.paste(entry, false) }
                    .buttonStyle(SettingsButtonStyle.primary)
                Button { model.closeZoom() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Back (Esc)"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Group {
                if let image = model.zoomImageForSelection {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .contentShape(Rectangle())
            .onTapGesture { model.closeZoom() }
        }
        .background(Color(white: 0.07))
    }

    /// Roh-Transkript eines nachbearbeiteten Diktats, unter dem Ergebnis.
    private func originalSection(_ original: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(AppTheme.border)
            Text("Original transcript")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.textTertiary)
            ScrollView {
                Text(verbatim: String(original.prefix(ClipboardHistoryViewModel.previewCharacterLimit)))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
        }
    }

    private func actionRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 6) {
            Button("Paste") { model.actions.paste(entry, false) }
                .buttonStyle(SettingsButtonStyle.primary)
            if model.canCorrect(entry) {
                Button("Correct & Paste") { model.actions.correctAndPaste(entry) }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .help(String(localized: "Fix spelling and grammar, then paste (⌘↩)"))
            }
            // Diktate sind ohnehin reiner Text; dort steht stattdessen "Original einfügen".
            if entry.kind == .text, entry.dictationMode == nil {
                Button("Paste as plain text") { model.actions.paste(entry, true) }
                    .buttonStyle(SettingsButtonStyle.standard)
            }
            if entry.kind == .image {
                Button("View Large") { model.openZoom() }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .help(String(localized: "View large (⌘Y)"))
            }
            if entry.dictationOriginal != nil {
                Button("Paste original") { model.actions.pasteOriginal(entry) }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .help(String(localized: "Paste what you said, before the mode rewrote it"))
            }
            Button { model.actions.togglePin(entry) } label: {
                if entry.isPinned { Text("Unpin") } else { Text("Pin") }
            }
            .buttonStyle(SettingsButtonStyle.standard)
            .help(String(localized: "Pin (⌘P)"))
            Button("Delete") { model.deleteEntry(entry) }
                .buttonStyle(SettingsButtonStyle.destructive)
                .help(String(localized: "Delete (⌘⌫)"))
        }
    }

    private func kindTitle(_ kind: ClipboardEntry.Kind) -> Text {
        switch kind {
        case .text: return Text("Text")
        case .image: return Text("Image")
        case .files: return Text("Files")
        }
    }

    private func detail(for entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .text:
            let count = entry.textLength
            return String(localized: "\(count) characters")
        case .image:
            if let w = entry.imageWidth, let h = entry.imageHeight {
                return "\(w) × \(h)"
            }
            return ""
        case .files:
            let count = entry.filePaths?.count ?? 0
            return String(localized: "\(count) files")
        }
    }

    // MARK: Tastenhinweise

    private var shortcutBar: some View {
        HStack(spacing: 12) {
            if model.isConfirmingClear {
                Text("Clear all entries except pinned ones?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer(minLength: 0)
                Button("Cancel") { model.isConfirmingClear = false }
                    .buttonStyle(SettingsButtonStyle.standard)
                Button("Clear History") { model.confirmClear() }
                    .buttonStyle(SettingsButtonStyle.destructive)
            } else {
                hint("↑↓", "Select")
                hint("↩", "Paste")
                hint("⌥↩", "Plain text")
                if model.quickActionsAvailable { hint("⌘↩", "Correct") }
                hint("⌘1-9", "Quick paste")
                hint("⌘D", "Dictations")
                hint("esc", "Close")
                Spacer(minLength: 0)
                footerButton("Clear History…", systemImage: "trash") { model.isConfirmingClear = true }
                footerButton("Settings…", systemImage: "gearshape") { model.actions.openSettings() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(AppTheme.header)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(AppTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ keys: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: keys)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 4)
                .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .fixedSize()
    }
}

// MARK: - Relative Zeit

enum ClipboardRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(from date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return String(localized: "just now") }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Schrift der Vorschau

/// Code, Logs, Pfade und Befehle in Festbreitenschrift, Fließtext in der
/// normalen Schrift. Rein, damit es ohne Ansicht testbar ist.
enum ClipboardPreviewStyle {
    private static let codeMarkers = ["{", "}", ";", "=>", "->", "</", "()", "::", "&&", "||", "$ ", "#!", "```"]

    static func prefersMonospace(_ text: String) -> Bool {
        let sample = String(text.prefix(4_000))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        // Eingerückte Zeilen (Stacktraces, Code, YAML) ab einem Drittel der Zeilen.
        let indented = lines.filter { $0.hasPrefix("\t") || $0.hasPrefix("  ") }.count
        if lines.count >= 2, Double(indented) / Double(lines.count) >= 0.3 { return true }
        if codeMarkers.contains(where: sample.contains) { return true }
        // Ein einzelnes Wort ohne Leerzeichen mit Pfad- oder Befehlszeichen.
        if lines.count == 1, !sample.contains(" "), sample.contains(where: { "/_~=".contains($0) }),
           !sample.hasPrefix("http") {
            return true
        }
        return false
    }
}

