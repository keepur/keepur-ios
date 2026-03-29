import SwiftUI

struct SetupView: View {
    let onConnect: () -> Void

    @State private var token = ""
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Keepur")
                    .font(.largeTitle.bold())
                Text("Connect to Beekeeper")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                SecureField("Beekeeper Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 40)

                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }

            Spacer()
            Spacer()
        }
    }

    private func connect() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isConnecting = true
        KeychainManager.token = trimmed
        Task {
            try? await Task.sleep(for: .seconds(1))
            isConnecting = false
            onConnect()
        }
    }
}
