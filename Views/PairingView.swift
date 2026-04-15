import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PairingView: View {
    let onPaired: () -> Void
    let capabilityManager: CapabilityManager

    @State private var host = BeekeeperConfig.host ?? ""
    @State private var code = ""
    @State private var deviceName = ""
    @State private var step = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var codeFieldFocused: Bool
    @FocusState private var hostFieldFocused: Bool

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Keepur")
                    .font(.largeTitle.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            switch step {
            case 0: hostEntryView
            case 1: codeEntryView
            default: nameEntryView
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40)
            }

            if isLoading {
                ProgressView()
            }

            Spacer()
            Spacer()
        }
    }

    private var subtitle: String {
        switch step {
        case 0: return "Enter your Beekeeper host"
        case 1: return "Enter the 6-digit pairing code from your admin dashboard"
        default: return "Name this device"
        }
    }

    // MARK: - Step 0: Host Entry

    private var hostEntryView: some View {
        VStack(spacing: 16) {
            TextField("beekeeper.example.com", text: $host)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled(true)
                .focused($hostFieldFocused)
                .padding(.horizontal, 40)
                .onSubmit(continueFromHost)

            Text("Your administrator will give you this address.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Continue", action: continueFromHost)
                .buttonStyle(.borderedProminent)
                .disabled(BeekeeperConfig.validate(host) == nil)
        }
        .onAppear { hostFieldFocused = true }
    }

    private func continueFromHost() {
        guard let normalized = BeekeeperConfig.validate(host) else {
            errorMessage = "Enter a valid hostname (e.g. beekeeper.example.com)"
            return
        }
        BeekeeperConfig.host = normalized
        host = normalized
        errorMessage = nil
        step = 1
        codeFieldFocused = true
    }

    // MARK: - Step 1: Code Entry

    private var codeEntryView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .padding(.horizontal, 40)

            TextField("", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($codeFieldFocused)
                .opacity(0)
                .frame(height: 1)
                .onChange(of: code) {
                    code = String(code.filter(\.isNumber).prefix(6))
                    if code.count == 6 {
                        step = 2
                    }
                }

            Button("Back") {
                code = ""
                errorMessage = nil
                step = 0
                hostFieldFocused = true
            }
            .font(.footnote)
        }
        .onAppear { codeFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let digit = index < code.count ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
        return Text(digit)
            .font(.system(size: 36, weight: .bold, design: .monospaced))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.tertiarySystemFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { codeFieldFocused = true }
    }

    // MARK: - Step 2: Device Name

    private var nameEntryView: some View {
        VStack(spacing: 16) {
            TextField("Device name", text: $deviceName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
                .disabled(isLoading)

            HStack(spacing: 12) {
                Button("Back") {
                    code = ""
                    errorMessage = nil
                    step = 1
                }
                .disabled(isLoading)

                Button("Continue") {
                    pair()
                }
                .buttonStyle(.borderedProminent)
                .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
    }

    // MARK: - Pairing

    private func pair() {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await APIManager.pair(code: code, name: trimmedName)
                KeychainManager.token = response.token
                KeychainManager.deviceId = response.deviceId
                KeychainManager.deviceName = response.deviceName

                await capabilityManager.refresh()

                if capabilityManager.lastError != nil {
                    // Roll back the token write so the user isn't left in a half-paired
                    // state with an orphaned credential that onAuthFailure silently swallowed.
                    KeychainManager.clearAll()
                    errorMessage = "Paired, but couldn't load hives. Check network and try again."
                    isLoading = false
                    return
                }

                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                #endif

                isLoading = false
                onPaired()
            } catch is APIManager.PairError {
                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                #endif

                errorMessage = "Invalid pairing code. Try again."
                isLoading = false
                code = ""
                step = 1
                codeFieldFocused = true
            } catch BeekeeperConfigError.hostNotConfigured {
                errorMessage = "Host not configured. Go back and enter your Beekeeper host."
                isLoading = false
            } catch {
                errorMessage = "Connection error. Check network."
                isLoading = false
            }
        }
    }
}
