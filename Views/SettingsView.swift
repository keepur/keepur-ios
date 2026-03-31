import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(KeychainManager.deviceName ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }

                    if let deviceId = KeychainManager.deviceId {
                        HStack {
                            Text("Device ID")
                            Spacer()
                            Text(String(deviceId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let sessionId = viewModel.currentSessionId {
                        HStack {
                            Text("Session")
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                        if viewModel.ws.isConnected {
                            viewModel.ws.disconnect()
                        } else {
                            viewModel.ws.connect()
                        }
                    }

                    Button("Unpair Device", role: .destructive) {
                        showUnpairConfirmation = true
                    }
                    .confirmationDialog(
                        "Unpair this device?",
                        isPresented: $showUnpairConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Unpair", role: .destructive) {
                            viewModel.unpair()
                            dismiss()
                        }
                    } message: {
                        Text("You will need a new pairing code from your admin to reconnect.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
