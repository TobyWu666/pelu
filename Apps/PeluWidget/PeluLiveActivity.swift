import ActivityKit
import PeluCore
import PeluUI
import SwiftUI
import WidgetKit

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: PeluActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            content(state: state.effective(at: context.date))
        }
    }

    private func content(state: PeluActivityAttributes.ContentState) -> some View {
        HStack(spacing: 20) {
            providerBlock(
                label: "Claude Code",
                percent: state.claudePercent,
                weekly: state.claudeWeeklyPercent,
                weeklyResetDate: state.claudeWeeklyResetDate,
                status: UsageStatus.from(percent: state.claudePercent)
            )

            Divider().frame(height: 44)

            providerBlock(
                label: "Codex",
                percent: state.codexPercent,
                weekly: state.codexWeeklyPercent,
                weeklyResetDate: state.codexWeeklyResetDate,
                status: UsageStatus.from(percent: state.codexPercent)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func providerBlock(
        label: String,
        percent: Double?,
        weekly: Double?,
        weeklyResetDate: Date?,
        status: UsageStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            Text(PercentFormatter.string(from: percent))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(status.tintColor)
                .lineLimit(1)

            UsageBar(percent: percent, tint: status.tintColor, height: 4)

            if let w = weekly {
                HStack(spacing: 6) {
                    Text("週")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    UsageBar(percent: w, tint: status.tintColor.opacity(0.55), height: 3)
                    Text(PercentFormatter.string(from: w))
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dynamic Island Logo

private struct LogoView: View {
    var size: CGFloat = 16

    var body: some View {
        Image("PeluSimpleLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.white)
    }
}

// MARK: - Live Activity Widget

struct PeluLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PeluActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TimelineView(.periodic(from: Date(), by: 60)) { clock in
                        let state = context.state.effective(at: clock.date)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(PercentFormatter.string(from: state.claudePercent))
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(UsageStatus.from(percent: state.claudePercent).tintColor)
                        }
                        .padding(.leading, 6)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    TimelineView(.periodic(from: Date(), by: 60)) { clock in
                        let state = context.state.effective(at: clock.date)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Codex")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(PercentFormatter.string(from: state.codexPercent))
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(UsageStatus.from(percent: state.codexPercent).tintColor)
                        }
                        .padding(.trailing, 6)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    LogoView(size: 20)
                }

            } compactLeading: {
                LogoView(size: 14)
            } compactTrailing: {
                TimelineView(.periodic(from: Date(), by: 60)) { clock in
                    let state = context.state.effective(at: clock.date)
                    Text(PercentFormatter.string(from: state.claudePercent))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(UsageStatus.from(percent: state.claudePercent).tintColor)
                }
            } minimal: {
                LogoView(size: 12)
            }
        }
    }
}
