import PeluCore
import PeluUI
import SwiftUI

@main
struct PeluApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var auth = AppAuth.shared
    @State private var showSplash = true
    @State private var splashOpacity = 1.0
    @State private var didScheduleSplash = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if auth.isPaired {
                    TabView {
                        PeluDashboardScreen()
                            .tabItem { Label("用量", systemImage: "waveform.path.ecg") }
                        PeluSettingsScreen()
                            .tabItem { Label("設定", systemImage: "gearshape") }
                    }
                    .transition(.opacity)
                } else {
                    PeluPairingScreen(auth: auth)
                        .transition(.opacity)
                }

                if showSplash {
                    SplashView()
                        .opacity(splashOpacity)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: auth.isPaired)
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
                // 每次啟動都註冊 APNs（silent push 不需要 UI 權限，但需要這個 token）
                // 這樣 Widget 才能靠背景 silent push 自動更新。
                // 配對完成前 token 沒人會用，但先拿到備著。
                let manager = NotificationManager.shared
                manager.ensureDeviceRegistered()
                await manager.refreshAuthorizationStatus()
                if manager.lowQuotaEnabled || manager.resetEnabled {
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
