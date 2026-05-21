import PeluCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct PeluDashboardView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let snapshot: UsageSnapshot
    private let refreshAction: (() async -> Void)?

    public init(snapshot: UsageSnapshot, refreshAction: (() async -> Void)? = nil) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(snapshot.metrics) { metric in
                    UsageMetricCard(metric: metric)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .scrollIndicators(.hidden)
        .background(MacScrollIndicatorHider())
        #endif
        .background(PeluTheme.background(for: colorScheme))
        .safeAreaInset(edge: .bottom) {
            bottomSpacer
        }
        .if(refreshAction != nil) { view in
            view.refreshable { await refreshAction?() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            HStack(alignment: .center, spacing: 12) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pelu")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    Text("Claude Code + Codex")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                }

                Spacer()

                StatusPill(source: snapshot.source)
            }
            Text("最後更新 \(UpdatedAtFormatter.string(from: snapshot.generatedAt))")
                .font(.subheadline)
                .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            #else
            HStack {
                Text("最後更新 \(UpdatedAtFormatter.string(from: snapshot.generatedAt))")
                    .font(.subheadline)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                Spacer()
                StatusPill(source: snapshot.source)
            }
            #endif
        }
        .padding(.bottom, 4)
    }

    private var bottomPadding: CGFloat {
        #if os(iOS)
        return 104
        #else
        return 28
        #endif
    }

    @ViewBuilder
    private var bottomSpacer: some View {
        Color.clear.frame(height: bottomPadding)
    }
}

#Preview {
    PeluDashboardView(snapshot: .demo())
}

#Preview("Dark") {
    PeluDashboardView(snapshot: .demo())
        .preferredColorScheme(.dark)
}

#if os(macOS)
private struct MacScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            hideScrollers(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            hideScrollers(from: nsView)
        }
    }

    private func hideScrollers(from view: NSView) {
        var current: NSView? = view
        while let candidate = current?.superview {
            if let scrollView = candidate as? NSScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.scrollerStyle = .overlay
                return
            }
            current = candidate
        }
    }
}
#endif
