import PeluCore
import PeluUI
import SwiftUI

@main
struct PeluApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = false
    @State private var showSplash = true
    @State private var splashOpacity = 1.0
    @State private var didScheduleSplash = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if onboardingCompleted {
                    TabView {
                        PeluDashboardScreen()
                            .tabItem { Label("用量", systemImage: "waveform.path.ecg") }
                        PeluHistoryScreen()
                            .tabItem { Label("歷史", systemImage: "calendar") }
                        PeluSettingsScreen()
                            .tabItem { Label("設定", systemImage: "gearshape") }
                    }
                    .transition(.opacity)
                } else {
                    iOSOnboardingView()
                        .transition(.opacity)
                }

                if showSplash {
                    SplashView()
                        .opacity(splashOpacity)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: onboardingCompleted)
            .onAppear {
                guard !didScheduleSplash else { return }
                didScheduleSplash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        splashOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        showSplash = false
                    }
                }
            }
            .task {
                // 設定頁 toggle 已開時自動續展 UNNotification 授權狀態。
                // CloudKit subscription 在 PeluDashboardScreen.task 註冊，跟 UI 渲染同時做。
                let manager = NotificationManager.shared
                await manager.refreshAuthorizationStatus()
                if manager.lowQuotaEnabled || manager.resetEnabled || manager.weeklyResetEnabled {
                    await manager.requestAuthorizationIfNeeded()
                }
            }
        }
    }
}

private struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 14) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .opacity(appeared ? 1 : 0)

                Text("Pelu")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }
}
