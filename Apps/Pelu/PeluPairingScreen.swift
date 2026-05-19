import PeluUI
import SwiftUI

struct PeluPairingScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var code: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    let auth: AppAuth

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)

                VStack(spacing: 8) {
                    Text("配對這支 iPhone")
                        .font(.title2.weight(.bold))
                    Text("在 Mac 的 Pelu menu bar 點 iPhone 圖示，輸入畫面上的 6 位數")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                codeField

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }

                Button(action: submit) {
                    HStack {
                        if isWorking { ProgressView().controlSize(.small) }
                        Text(isWorking ? "配對中…" : "配對")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(canSubmit ? PeluTheme.primaryText(for: colorScheme).opacity(0.9) : .secondary.opacity(0.3))
                    .foregroundStyle(canSubmit ? Color(.systemBackground) : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isWorking)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
        }
    }

    private var canSubmit: Bool {
        code.count == 6 && code.allSatisfy(\.isNumber)
    }

    private var codeField: some View {
        TextField("000 000", text: $code)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .monospacedDigit()
            .tracking(8)
            .padding(.vertical, 14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: code) { _, new in
                code = String(new.filter(\.isNumber).prefix(6))
            }
    }

    private func submit() {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await auth.claim(code: code)
            } catch let pairing as AppAuth.PairingError {
                errorMessage = pairing.errorDescription
            } catch {
                errorMessage = "配對失敗：\(error.localizedDescription)"
            }
        }
    }
}
