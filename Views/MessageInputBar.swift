import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentData: Equatable {
    let data: Data
    let name: String
    let mimeType: String
}

struct MessageInputBar: View {
    @Binding var messageText: String
    @Binding var pendingAttachment: AttachmentData?
    @ObservedObject var speechManager: SpeechManager
    var onSend: () -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showDocumentPicker = false
    @State private var showAttachmentOptions = false
    @State private var showPhotoPicker = false
    @State private var showCameraPlaceholder = false
    @State private var attachmentError: String?
    private static let maxAttachmentSize = 10 * 1024 * 1024 // 10 MB

    var body: some View {
        VStack(spacing: 0) {
            if let attachment = pendingAttachment {
                attachmentPreview(name: attachment.name, data: attachment.data, mimeType: attachment.mimeType)
                    .padding(.top, KeepurTheme.Spacing.s2)
            }

            HStack(spacing: KeepurTheme.Spacing.s2) {
                Button { showAttachmentOptions = true } label: {
                    Image(systemName: KeepurTheme.Symbol.plus)
                        .font(.system(size: 26))
                        .foregroundStyle(KeepurTheme.Color.fgMuted)
                }

                TextField("Message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KeepurTheme.Font.body)
                    .padding(.horizontal, KeepurTheme.Spacing.s3)
                    .padding(.vertical, KeepurTheme.Spacing.s2)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.pill)
                            .fill(.ultraThinMaterial)
                    )
                    .lineLimit(1...6)
                    .onSubmit { onSend() }

                VoiceButton(speechManager: speechManager)

                Button { onSend() } label: {
                    Image(systemName: KeepurTheme.Symbol.send)
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, KeepurTheme.Spacing.s3)
            .padding(.vertical, KeepurTheme.Spacing.s2)
        }
        .background(.ultraThinMaterial)
        .onChange(of: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    attachmentError = "Could not load the selected photo."
                    selectedPhoto = nil
                    return
                }
                guard data.count <= Self.maxAttachmentSize else {
                    attachmentError = "File is too large. Maximum size is 10 MB."
                    selectedPhoto = nil
                    return
                }
                let contentType = item.supportedContentTypes.first
                let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
                let ext = contentType?.preferredFilenameExtension ?? "jpg"
                let name = "image_\(Int(Date().timeIntervalSince1970)).\(ext)"
                pendingAttachment = AttachmentData(data: data, name: name, mimeType: mimeType)
                selectedPhoto = nil
            }
        }
        .onReceive(speechManager.$liveText) { newText in
            guard !newText.isEmpty else { return }
            messageText = newText
        }
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                loadAttachment(from: url)
            case .failure:
                break
            }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadAttachment(from: url)
            return true
        }
        #endif
        .alert("Attachment Error", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .sheet(isPresented: $showAttachmentOptions) {
            KeepurActionSheet(
                title: "Attach",
                subtitle: "Add a file or photo to the message.",
                actions: [
                    .init(
                        symbol: "doc",
                        title: "Choose file",
                        subtitle: "Browse documents on this device"
                    ) {
                        showAttachmentOptions = false
                        DispatchQueue.main.async { showDocumentPicker = true }
                    },
                    .init(
                        symbol: "photo",
                        title: "Photo library",
                        subtitle: "Pick from your photos"
                    ) {
                        showAttachmentOptions = false
                        DispatchQueue.main.async { showPhotoPicker = true }
                    },
                    .init(
                        symbol: "camera",
                        title: "Take photo",
                        subtitle: "Use the camera now"
                    ) {
                        showAttachmentOptions = false
                        DispatchQueue.main.async { showCameraPlaceholder = true }
                    },
                ]
            )
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .alert(
            "Camera capture coming soon",
            isPresented: $showCameraPlaceholder
        ) {
            Button("OK", role: .cancel) { showCameraPlaceholder = false }
        } message: {
            Text("Take photo will be wired up when KPR-159 lands. For now, choose a file or pick from your photo library.")
        }
    }

    // MARK: - Private

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil
    }

    private func loadAttachment(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "Could not read the selected file."
            return
        }
        guard data.count <= Self.maxAttachmentSize else {
            attachmentError = "File is too large. Maximum size is 10 MB."
            return
        }
        pendingAttachment = AttachmentData(data: data, name: url.lastPathComponent, mimeType: url.mimeType)
    }

    private func attachmentPreview(name: String, data: Data, mimeType: String) -> some View {
        HStack {
            if mimeType.hasPrefix("image/"), let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
            Text(name)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .lineLimit(1)
            Spacer()
            Button { pendingAttachment = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
        }
        .padding(.horizontal, KeepurTheme.Spacing.s3)
        .padding(.vertical, KeepurTheme.Spacing.s1 + 2)
        .background(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm).fill(KeepurTheme.Color.bgSunkenDynamic))
        .padding(.horizontal, KeepurTheme.Spacing.s1)
    }
}
