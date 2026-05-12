import SwiftUI

struct AgentResourceSummaryButton: View {
    let descriptors: [AgentResourceSessionDescriptor]

    @State private var snapshot = AgentResourceSnapshot.empty
    @State private var isPopoverPresented = false
    @State private var isHovered = false

    private var shouldPoll: Bool {
        isPopoverPresented || !descriptors.isEmpty
    }

    private var pollingKey: String {
        let processKey = descriptors
            .map { "\($0.id.uuidString):\($0.rootProcessID ?? 0)" }
            .joined(separator: ",")
        return "\(shouldPoll)-\(processKey)"
    }

    var body: some View {
        Button {
            refresh()
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9, weight: .medium))
                Text(summaryText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textTertiary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? AgentTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Session-Ressourcen anzeigen")
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
            AgentResourcePopover(snapshot: snapshot, onRefresh: refresh)
                .frame(width: 420)
        }
        .onAppear(perform: refresh)
        .onChange(of: descriptors) { _, _ in
            refresh()
        }
        .task(id: pollingKey) {
            guard shouldPoll else {
                refresh()
                return
            }

            // Schnelles Refresh nur wenn der Popover offen ist — der User
            // schaut aktiv hin. Bei geschlossenem Popover reicht ein
            // langsamerer Refresh (Badge zeigt nur Counter + Total).
            // Reduziert die /bin/ps-Forks von 30 → 12 pro Minute wenn nur
            // das Badge gerendert wird.
            while !Task.isCancelled {
                refresh()
                let interval: Duration = isPopoverPresented
                    ? .seconds(2)
                    : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var isActive: Bool { snapshot.runningSessionCount > 0 }

    private var rowBackground: Color {
        if isActive { return AgentTheme.surface }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }

    private var summaryText: String {
        guard snapshot.runningSessionCount > 0 else { return "0" }
        return "\(snapshot.runningSessionCount) · \(AgentResourceFormat.cpu(snapshot.totalCPUPercent)) · \(AgentResourceFormat.memory(snapshot.totalMemoryBytes))"
    }

    private func refresh() {
        let descriptors = descriptors
        Task {
            let next = await Task.detached(priority: .utility) {
                AgentResourceMonitor().snapshot(for: descriptors)
            }.value
            snapshot = next
        }
    }
}

private struct AgentResourcePopover: View {
    let snapshot: AgentResourceSnapshot
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Resource Usage")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Aktualisieren")
            }
            .padding(14)

            HStack(spacing: 20) {
                metricColumn("CPU", AgentResourceFormat.cpu(snapshot.totalCPUPercent))
                metricColumn("Memory", AgentResourceFormat.memory(snapshot.totalMemoryBytes))
                if let ramShare = snapshot.ramSharePercent {
                    metricColumn("RAM Share", AgentResourceFormat.percent(ramShare))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider()

            if snapshot.projects.isEmpty {
                Text("Keine laufenden Agent-Sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(AgentTheme.panel)
    }

    private func metricColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectSection(_ project: AgentResourceProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(project.projectName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(AgentResourceFormat.cpu(project.cpuPercent))  \(AgentResourceFormat.memory(project.memoryBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            ForEach(project.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProviderIcon(
                            provider: session.provider,
                            size: 12,
                            tint: Color(hex: session.provider == .codex ? "#32D74B" : "#FF9F0A")
                        )
                        .frame(width: 18)
                        Text(session.title)
                            .lineLimit(1)
                        Spacer()
                        Text("\(AgentResourceFormat.cpu(session.cpuPercent))  \(AgentResourceFormat.memory(session.memoryBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(session.processes) { process in
                        HStack {
                            Text(process.command)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(AgentResourceFormat.cpu(process.cpuPercent))  \(AgentResourceFormat.memory(process.memoryBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AgentTheme.background.opacity(0.35))
            }
        }
    }
}

private enum AgentResourceFormat {
    static func cpu(_ value: Double) -> String {
        "\(String(format: "%.1f", max(0, value)))%"
    }

    static func percent(_ value: Double) -> String {
        "\(String(format: "%.0f", max(0, value)))%"
    }

    static func memory(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 {
            return "\(String(format: "%.1f", megabytes)) MB"
        }
        return "\(String(format: "%.2f", megabytes / 1024)) GB"
    }
}
