import CoreGraphics
import SwiftUI
@testable import WhisperM8

/// Fixture für „Chat am Nutzungslimit“ (WM8-69): Seitenleiste, Tab und
/// Kachelkopf neben den anderen Status, damit Form und Farbe vergleichbar sind.
extension UISnapshotGallery {
    static func usageLimitFixtures() -> [Fixture] {
        let limit = AgentUsageLimit(resetsAt: Date().addingTimeInterval(95 * 60), kind: "five_hour", since: nil)
        func row(_ title: String, _ status: AgentSessionRuntimeStatus?, limited: Bool = false) -> some View {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(AgentTheme.textPrimary)
                Spacer(minLength: 6)
                if limited { AgentUsageLimitLabel(limit: limit) } else { AgentStatusIndicator(status: status) }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        return [
            Fixture(name: "nutzungslimit-status", size: CGSize(width: 640, height: 260)) {
                AnyView(HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("SIDEBAR").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentTheme.textTertiary)
                        row("Fin · Insel: Tastatur", .working)
                        row("Dex · Ticket-Board", .awaitingInput)
                        row("Ole · Terminal-Tab", .idle)
                        row("Gus · Chat am Limit", .idle, limited: true)
                    }
                    .frame(width: 280)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TABS + KACHEL").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentTheme.textTertiary)
                        HStack(spacing: 6) {
                            AgentStatusIndicator(status: .idle, compact: true, usageLimit: limit)
                            Text("Gus · Chat am Limit").font(.system(size: 11)).foregroundStyle(AgentTheme.textSecondary)
                            AgentStatusIndicator(status: .working, compact: true, usageLimit: limit)
                            Text("arbeitet wieder").font(.system(size: 11)).foregroundStyle(AgentTheme.textSecondary)
                        }
                        HStack(spacing: 8) {
                            AgentStatusIndicator(status: .idle, usageLimit: limit)
                            Text("Gus · Chat am Limit").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AgentTheme.textPrimary)
                            Text("RankM8").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentTheme.textTertiary)
                            AgentUsageLimitLabel(limit: limit)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AgentTheme.header)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentTheme.background))
            },
        ]
    }
}
