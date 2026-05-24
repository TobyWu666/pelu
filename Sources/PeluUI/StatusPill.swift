import PeluCore
import SwiftUI

struct StatusPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let source: ConnectionSource
    /// When true, overrides `source` and renders as a red "斷線" pill — used
    /// by the dashboard header when no Mac snapshot has arrived for >5 min.
    var isDisconnected: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(PeluTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(PeluTheme.surface(for: colorScheme))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(PeluTheme.border(for: colorScheme), lineWidth: 1)
        }
    }

    private var label: String {
        isDisconnected ? "斷線" : source.displayName
    }

    private var tint: Color {
        if isDisconnected { return .red }
        switch source {
        case .local:
            return PeluTheme.brandTeal(for: colorScheme)
        case .cloud:
            return PeluTheme.sky
        case .cache:
            return PeluTheme.amber
        case .demo:
            return PeluTheme.slate500
        }
    }
}
