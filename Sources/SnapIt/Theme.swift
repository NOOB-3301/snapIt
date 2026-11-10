import SwiftUI

enum Theme {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let rSmall: CGFloat = 6, rCard: CGFloat = 10, rComposer: CGFloat = 14
}

/// Pill used for quick actions and file chips.
struct ChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(configuration.isPressed ? 1 : 0.6), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Borderless SF Symbol button with a hover background. Always pair with .help().
struct IconStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 26)
            .background(.quaternary.opacity(hover || configuration.isPressed ? 0.8 : 0), in: RoundedRectangle(cornerRadius: Theme.rSmall))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Which MCP servers Claude may use; the count shows when any are ticked.
struct McpMenu: View {
    @ObservedObject private var store = McpStore.shared
    let onChange: () -> Void
    var disabled = false

    var body: some View {
        Menu {
            if store.names.isEmpty {
                Text("No servers in ~/.claude.json")
            } else {
                ForEach(store.names, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { store.selected.contains(name) },
                        set: { on in
                            store.selected.removeAll { $0 == name }
                            if on { store.selected.append(name) }
                            onChange()
                        }))
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "powerplug")
                if !store.selected.isEmpty { Text("\(store.selected.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
        }
        .menuStyle(.button).buttonStyle(IconStyle()).menuIndicator(.hidden).fixedSize()
        .disabled(disabled)
        .help("MCP servers Claude may use").accessibilityLabel("MCP servers")
    }
}
