import MarkdownUI
import SwiftUI

extension MarkdownUI.Theme {
    static let keepur = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(.em(1))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(.primary)
            BackgroundColor(Color(.systemGray6))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.3))
                }
                .markdownMargin(top: 16, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.15))
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
}
