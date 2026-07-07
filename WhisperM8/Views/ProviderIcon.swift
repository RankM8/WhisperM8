import AppKit
import SwiftUI

struct ProviderIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 11
    var tint: Color = AgentTheme.textSecondary

    var body: some View {
        if let nsImage = NSImage(named: provider.assetName) {
            let templateImage = Self.templateCopy(nsImage)
            Image(nsImage: templateImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(tint)
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }

    private static func templateCopy(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.isTemplate = true
        return copy
    }
}

/// Session-bewusstes Icon: Terminals zeigen das Terminal-Symbol statt des
/// (Platzhalter-)Provider-Logos — überall dort verwenden, wo das Icon eine
/// konkrete Session repräsentiert (Sidebar-Rows, Tab-Chips, Drag-Previews).
struct AgentSessionIcon: View {
    let session: AgentChatSession
    var size: CGFloat = 11
    var tint: Color = AgentTheme.textSecondary

    var body: some View {
        if session.isTerminal {
            Image(systemName: "terminal")
                .font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            ProviderIcon(provider: session.provider, size: size, tint: tint)
        }
    }
}
