import PeluCore
import PeluUI
import SwiftUI

struct PeluDashboardScreen: View {
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @State private var aggregate = AggregateSnapshot.demo()
    @State private var isRefreshing = false
    @State private var errorMessage: String?

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
            .task { await refresh() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                Task { await refresh() }
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
        } catch {
            errorMessage = "無法取得資料，請確認 Mac app 是否開啟並連線正常。"
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
