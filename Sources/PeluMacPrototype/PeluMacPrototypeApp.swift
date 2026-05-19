import PeluCore
import PeluUI
import SwiftUI

@main
struct PeluMacPrototypeApp: App {
    private let snapshot = UsageSnapshot.demo()

    var body: some Scene {
        MenuBarExtra(menuTitle, systemImage: "waveform.path.ecg") {
            PeluDashboardView(snapshot: snapshot)
                .frame(width: 360, height: 520)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        let claude = snapshot.metric(for: .claudeCode)?.usedPercent ?? 0
        let codex = snapshot.metric(for: .codex)?.usedPercent ?? 0
        return "Pelu \(Int(claude.rounded()))% · \(Int(codex.rounded()))%"
    }
}
