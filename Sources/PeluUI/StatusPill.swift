import PeluCore
import SwiftUI

struct StatusPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let source: ConnectionSource

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(source.displayName)
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

    private var tint: Color {
        switch source {
        case .local:
            PeluTheme.brandTeal(for: colorScheme)
        case .cloud:
            PeluTheme.sky
        case .cache:
            PeluTheme.amber
        case .demo:
            PeluTheme.slate500
        }
    }
}
