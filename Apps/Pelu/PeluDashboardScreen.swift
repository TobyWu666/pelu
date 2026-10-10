import PeluCore
import PeluUI
import SwiftUI

struct PeluDashboardScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @State private var aggregate = AggregateSnapshot.demo()
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    // 自適應 polling 狀態 — 比固定 5 分鐘 timer 對 Codex/Claude 在繁忙
    // 期間的 % 跳動更敏感。Active 心跳 60s、stable 5 次（= 5 分鐘無變動）
    // 後退回 idle 300s；任何 nudge（前景、silent push、手動 refresh）
    // 都重置 stableTicks 並立刻重啟 polling task。
    @State private var lastSignature: String?
    @State private var stableTicks: Int = 0
    @State private var pollingNonce: Int = 0
    private static let activeInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 300
    private static let stableTicksToIdle: Int = 5

    private static let syncer = CloudKitSyncer(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PeluAggregateDashboardView(aggregate: aggregate) {
                    await refresh()
                    nudgePolling()
                }

                if let errorMessage {
                    errorBanner(errorMessage)
                        .padding()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: pollingNonce) {
                if pollingNonce == 0 {
                    loadCachedAggregate()
                    // Subscribe once on first appearance; CKQuerySubscription
                    // handles background updates afterwards.
                    try? await Self.syncer.ensureSubscriptionRegistered()
                }
                await pollingLoop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .peluUsageDidUpdate)) { _ in
                // Silent-push refreshes are performed by AppDelegate and written
                // to the app-group store; reflect that result without a second fetch.
                loadCachedAggregate()
                nudgePolling()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { nudgePolling() }
            }
            .onChange(of: liveActivityEnabled) { _, enabled in
                if enabled {
                    nudgePolling()
                } else {
                    LiveActivityManager.shared.end()
                }
            }
        }
    }

    // MARK: - Adaptive polling

    /// 重置 stableTicks 並 bump nonce 讓 `.task(id:)` 取消舊 polling 並重啟。
    /// 新的 task 第一輪 sleep 就會用 activeInterval（60s）。
    private func nudgePolling() {
        stableTicks = 0
        pollingNonce &+= 1
    }

    @MainActor
    private func pollingLoop() async {
        while !Task.isCancelled {
            await refresh()
            updateCadence()

            let interval: TimeInterval = stableTicks >= Self.stableTicksToIdle
                ? Self.idleInterval
                : Self.activeInterval

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                // Cancelled (e.g. view disappeared or nudge bumped nonce);
                // exit cleanly so SwiftUI can re-enter with the new task.
                return
            }
        }
    }

    private func updateCadence() {
        let sig = currentSignature()
        if sig != lastSignature {
            stableTicks = 0
        } else {
            stableTicks += 1
        }
        lastSignature = sig
    }

    /// 簽名只取每個 (mac × provider) 的整數 usedPercent — 0.4 → 0.5 之類
    /// 的浮動不會誤觸發 "變化"。整數變動才算「有事發生」。
    private func currentSignature() -> String {
        aggregate.macs
            .flatMap { mac in
                mac.snapshot.metrics.map { metric in
                    let pct = metric.usedPercent.map { Int($0.rounded()) } ?? -1
                    return "\(mac.macId)|\(metric.provider.rawValue)|\(pct)"
                }
            }
            .sorted()
            .joined(separator: ",")
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
