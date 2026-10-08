import PeluCore
import PeluUI
import SwiftUI

@main
struct PeluMacPrototypeApp: App {
    @Environment(\.openWindow) private var openWindow
    private let snapshot = UsageSnapshot.demo()

    var body: some Scene {
        MenuBarExtra(menuTitle, systemImage: "waveform.path.ecg") {
            PeluMacDashboardView(snapshot: snapshot, refreshAction: {}, analysisAction: { openWindow(id: "analysis") })
                .frame(width: 392)
        }
        .menuBarExtraStyle(.window)
        Window("Pelu 用量分析 · 預覽", id: "analysis") {
            PeluMacAnalysisView(snapshot: snapshot, history: MacUsageHistory())
        }
    }

    private var menuTitle: String {
        let claude = snapshot.metric(for: .claudeCode)?.usedPercent ?? 0
        let codex = snapshot.metric(for: .codex)?.usedPercent ?? 0
        return "Pelu \(Int(claude.rounded()))% · \(Int(codex.rounded()))%"
    }
}
