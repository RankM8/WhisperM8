import CoreGraphics
import SwiftUI
@testable import WhisperM8

/// Fixtures für die Arbeitsordner-Marke (WM8-60): Kachelkopf mit Konto-Marke
/// und Ort/Branch in zwei Varianten, dazu Tab und Seitenleisten-Zeile mit dem
/// kleinen Zeichen.
extension UISnapshotGallery {
    private static let workingCopyCases: [(title: String, account: String, copy: AgentWorkingCopy)] = [
        ("Jarvis · Supervisor", "main",
         AgentWorkingCopy(kind: .mainFolder, path: "/Users/demo/repos/whisperm8", name: nil, branch: "main")),
        ("WM8-60 Gus · Arbeitsordner: je Chat anzeigen", "RankM8",
         AgentWorkingCopy(kind: .worktree, path: "/Users/demo/repos/whisperm8/.claude/worktrees/bindung-fremdes-transcript",
                          name: "bindung-fremdes-transcript", branch: "feat/WM8-60-arbeitsordner-anzeige")),
        ("Ole · Terminal-Tab: Zähler", "main",
         AgentWorkingCopy(kind: .worktree, path: "/Users/demo/repos/whisperm8/.claude/worktrees/neustart",
                          name: "neustart", branch: "neustart/integration")),
        ("Codex · Notizen", "main",
         AgentWorkingCopy(kind: .otherFolder, path: "/tmp/skizze", name: "skizze", branch: nil)),
    ]

    private struct HeaderRow: View {
        let title: String
        let account: String
        let copy: AgentWorkingCopy

        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(AgentTheme.statusWorking).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(account)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AgentTheme.textTertiary.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .layoutPriority(0.5)
                AgentWorkingCopyBadge(copy: copy)
                Spacer(minLength: 6)
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AgentTheme.header)
        }
    }

    private struct TabAndSidebar: View {
        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SIDEBAR").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentTheme.textTertiary)
                        .padding(.bottom, 4)
                    ForEach(Array(UISnapshotGallery.workingCopyCases.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Circle().fill(AgentTheme.textTertiary).frame(width: 6, height: 6)
                            Text(item.title).font(.system(size: 12)).foregroundStyle(AgentTheme.textPrimary)
                                .lineLimit(1).truncationMode(.tail)
                            AgentWorkingCopyMarker(copy: item.copy)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 24)
                    }
                }
                .frame(width: 300, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text("TABS").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentTheme.textTertiary)
                        .padding(.bottom, 4)
                    HStack(spacing: 2) {
                        ForEach(Array(UISnapshotGallery.workingCopyCases.prefix(3).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 5) {
                                AgentWorkingCopyMarker(copy: item.copy)
                                Text(item.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(index == 1 ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(width: 150, height: 26)
                            .background(index == 1 ? AgentTheme.tabSelected : AgentTheme.tabBar)
                        }
                    }
                }
            }
        }
    }

    static func workingCopyFixtures() -> [Fixture] {
        // Breit (Einzelkachel) und schmal (vier Spalten, ~400 pt je Kachel).
        func headers(_ name: String, width: CGFloat) -> Fixture {
            Fixture(name: "arbeitsordner-kachelkopf-\(name)", size: CGSize(width: width, height: 160)) {
                AnyView(VStack(spacing: 1) {
                    ForEach(Array(workingCopyCases.enumerated()), id: \.offset) { _, item in
                        HeaderRow(title: item.title, account: item.account, copy: item.copy)
                    }
                }
                .background(AgentTheme.border)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentTheme.background))
            }
        }
        return [
            headers("breit", width: 720),
            headers("schmal", width: 424),
            Fixture(name: "arbeitsordner-tab-seitenleiste", size: CGSize(width: 820, height: 150)) {
                AnyView(TabAndSidebar()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AgentTheme.background))
            },
        ]
    }
}
