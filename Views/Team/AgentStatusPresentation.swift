import SwiftUI

extension AgentStatus {
    struct Presentation {
        let label: String
        let headerText: String?
        let isActive: Bool
        let tint: KeepurStatusPill.Tint
    }

    var presentation: Presentation {
        switch self {
        case .idle:
            return Presentation(label: "Idle", headerText: nil, isActive: false, tint: .success)
        case .processing:
            return Presentation(label: "Processing", headerText: "working", isActive: true, tint: .warning)
        case .error:
            return Presentation(label: "Error", headerText: "error", isActive: false, tint: .danger)
        case .stopped:
            return Presentation(label: "Stopped", headerText: "stopped", isActive: false, tint: .danger)
        case .unknown(let raw):
            return Presentation(label: raw.prefix(1).uppercased() + raw.dropFirst(),
                                headerText: raw, isActive: false, tint: .muted)
        }
    }
}
