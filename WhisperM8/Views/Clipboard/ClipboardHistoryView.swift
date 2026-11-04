import AppKit
import SwiftUI

// MARK: - Verlaufs-Fenster

/// Suchfeld, Liste (Angepinnte oben), Vorschau und Tastenhinweise.
/// Tasten laufen über das Panel (`ClipboardPanel`), nicht über SwiftUI: so
/// bleibt das Suchfeld für Text zuständig und die Befehle sind fensterweit gleich.
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryViewModel
    @FocusState private var searchFocused: Bool
    var now: Date = Date()

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            searchBar(count: list.count)
            Divider().overlay(AppTheme.border)
            HStack(spacing: 0) {
                listColumn(list)
                    .frame(width: 330)
                Divider().overlay(AppTheme.border)
                previewColumn
            }
            Divider().overlay(AppTheme.border)
            shortcutBar
        }
        .frame(width: 760, height: 460)
        .background(AppTheme.panel)
        .onAppear { searchFocused = true }
    }

    // MARK: Suche

    private func searchBar(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textTertiary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            Text("Items: \(count)")
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
            let pinned = list.filter(\.isPinned)
            let rest = list.filter { !$0.isPinned }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !pinned.isEmpty {
                            groupHeader("Pinned")
                            ForEach(Array(pinned.enumerated()), id: \.element.id) { index, entry in
                                row(entry, number: index + 1)
                            }
                        }
                        if !rest.isEmpty {
                            if !pinned.isEmpty { groupHeader("History") }
                            ForEach(Array(rest.enumerated()), id: \.element.id) { index, entry in
                                row(entry, number: pinned.count + index + 1)
                            }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.preview.isEmpty ? " " : entry.preview)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: subtitle(for: entry))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            Spacer(minLength: 4)
            if entry.kind == .image, let image = model.thumbnails[entry.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 24)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? AppTheme.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.actions.paste(entry, false) }
        .onTapGesture { model.select(entry.id) }
        .id(entry.id)
    }

    @ViewBuilder
    private func leadingIcon(_ entry: ClipboardEntry) -> some View {
        if let icon = model.appIcon(for: entry) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: symbol(for: entry.kind))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 18, height: 18)
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

    private func subtitle(for entry: ClipboardEntry) -> String {
        let time = ClipboardRelativeTime.string(from: entry.lastCopiedAt, now: now)
        if let name = entry.sourceName, !name.isEmpty { return "\(name) · \(time)" }
        return time
    }

    // MARK: Vorschau

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = model.selectedEntry {
                HStack {
                    kindTitle(entry.kind)
                    Spacer()
                    Text(verbatim: detail(for: entry))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textTertiary)

                if entry.kind == .image {
                    if let image = model.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border))
                            .frame(maxWidth: .infinity, maxHeight: 280)
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        Text(verbatim: model.previewText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                actionRow(entry)
            } else {
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.surface)
    }

    private func actionRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 6) {
            Button("Paste") { model.actions.paste(entry, false) }
                .buttonStyle(SettingsButtonStyle.primary)
            if entry.kind == .text {
                Button("Paste as plain text") { model.actions.paste(entry, true) }
                    .buttonStyle(SettingsButtonStyle.standard)
            }
            Button(entry.isPinned ? "Unpin" : "Pin") { model.actions.togglePin(entry) }
                .buttonStyle(SettingsButtonStyle.standard)
            Button("Delete") { model.deleteEntry(entry) }
                .buttonStyle(SettingsButtonStyle.destructive)
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
            let count = (entry.text ?? entry.preview).count
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
        HStack(spacing: 14) {
            hint("↑↓", "Select")
            hint("↩", "Paste")
            hint("⌥↩", "Plain text")
            hint("⌘1–9", "Quick paste")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            hint("esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppTheme.header)
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
                .foregroundStyle(AppTheme.textTertiary)
        }
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
