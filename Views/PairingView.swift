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
    @FocusState private var deviceNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s6) {
            Spacer()

            VStack(spacing: KeepurTheme.Spacing.s2) {
                Image(systemName: KeepurTheme.Symbol.server)
                    .font(.system(size: 48))
                    .foregroundStyle(KeepurTheme.Color.honey500)

                Text("Keepur")
                    .font(KeepurTheme.Font.h1)
                    .tracking(KeepurTheme.Font.lsH1)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)

                Text(subtitle)
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, KeepurTheme.Spacing.s7)
            }

            switch step {
            case 0: hostEntryView
            case 1: codeEntryView
            default: nameEntryView
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.danger)
                    .padding(.horizontal, KeepurTheme.Spacing.s7)
            }

            if isLoading {
                ProgressView()
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeepurTheme.Color.bgPageDynamic)
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
        VStack(spacing: KeepurTheme.Spacing.s4) {
            keepurTextField(
                placeholder: "beekeeper.example.com",
                text: $host,
                focus: $hostFieldFocused
            )
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled(true)
            .onSubmit(continueFromHost)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Text("Your administrator will give you this address.")
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .multilineTextAlignment(.center)
                .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Continue", action: continueFromHost)
                .buttonStyle(KeepurPrimaryButtonStyle())
                .disabled(BeekeeperConfig.validate(host) == nil)
                .padding(.horizontal, KeepurTheme.Spacing.s7)
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
        VStack(spacing: KeepurTheme.Spacing.s4) {
            HStack(spacing: KeepurTheme.Spacing.s2) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .padding(.horizontal, KeepurTheme.Spacing.s7)

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
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        }
        .onAppear { codeFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let digit = index < code.count
            ? String(code[code.index(code.startIndex, offsetBy: index)])
            : ""
        return Text(digit)
            .font(.custom(KeepurTheme.FontName.monoBold, size: 32))
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(KeepurTheme.Color.charcoal900.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
            .contentShape(Rectangle())
            .onTapGesture { codeFieldFocused = true }
    }

    // MARK: - Step 2: Device Name

    private var nameEntryView: some View {
        VStack(spacing: KeepurTheme.Spacing.s4) {
            keepurTextField(
                placeholder: "Device name",
                text: $deviceName,
                focus: $deviceNameFieldFocused
            )
            .disabled(isLoading)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Continue") {
                pair()
            }
            .buttonStyle(KeepurPrimaryButtonStyle())
            .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Back") {
                code = ""
                errorMessage = nil
                step = 1
            }
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .disabled(isLoading)
        }
        .onAppear { deviceNameFieldFocused = true }
    }

    // MARK: - Branded text field

    /// Wax-surface text field with 1px wax-200 border and a honey focus ring.
    /// Inline helper for now — extract to Theme/Components/ once a second
    /// screen needs it (see Theme/Components/PrimaryButton.swift for the
    /// extraction pattern).
    private func keepurTextField(
        placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding
    ) -> some View {
        TextField(placeholder, text: text)
            .font(KeepurTheme.Font.body)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            .multilineTextAlignment(.center)
            .focused(focus)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .padding(.horizontal, KeepurTheme.Spacing.s4)
            .background(KeepurTheme.Color.bgSurfaceDynamic)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)
                    .stroke(KeepurTheme.Color.borderDefaultDynamic, lineWidth: 1)
            )
            .keepurFocusRing(focus.wrappedValue, radius: KeepurTheme.Radius.sm)
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
                    // Roll back the credentials only — leave BeekeeperConfig.host alone
                    // so the user can retry without re-entering the host.
                    KeychainManager.token = nil
                    KeychainManager.deviceId = nil
                    KeychainManager.deviceName = nil
                    UserDefaults.standard.removeObject(forKey: "selectedHive")
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
