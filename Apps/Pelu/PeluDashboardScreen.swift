import PeluCore
import PeluUI
import SwiftUI

struct PeluDashboardScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @State private var aggregate = AggregateSnapshot.demo()
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private static let syncer = CloudKitSyncer(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PeluAggregateDashboardView(aggregate: aggregate) {
                    await refresh()
                }

                if let errorMessage {
                    errorBanner(errorMessage)
                        .padding()
                }
            }
            .navigationTitle("Pelu")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                loadCachedAggregate()
                // Subscribe once on first appearance; CKQuerySubscription handles
                // background updates afterwards. The fetch follows.
                try? await Self.syncer.ensureSubscriptionRegistered()
                await refresh()
            }
            // Polling is just a fallback in case the subscription push is throttled.
            // CloudKit + Apple's APNs is usually <10s, so 5 minutes is plenty.
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                Task { await refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peluUsageDidUpdate)) { _ in
                // Silent-push refreshes are performed by AppDelegate and written
                // to the app-group store; reflect that result without a second fetch.
                loadCachedAggregate()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await refresh() }
                }
            }
            .onChange(of: liveActivityEnabled) { _, enabled in
                if enabled {
                    Task { await refresh() }
                } else {
                    LiveActivityManager.shared.end()
                }
            }
        }
    }

    // MARK: - Refresh

    private func loadCachedAggregate() {
        guard let store = AppGroupStore(),
              let cached = try? store.loadLatestAggregate() else { return }
        aggregate = cached
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            aggregate = try await UsageSurfaceUpdater.fetchFromCloud(
                updateLiveActivity: liveActivityEnabled
            )
            errorMessage = nil
        } catch UsageSurfaceUpdater.UpdaterError.accountUnavailable(let status) {
            errorMessage = CloudKitAccountChecker.displayMessage(for: status)
        } catch {
            errorMessage = "暫時取不到資料，請確認 Mac 已開啟 Pelu。"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text(message).font(.footnote.weight(.medium)).foregroundStyle(.primary)
            Spacer()
            Button { errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    PeluDashboardScreen()
}
