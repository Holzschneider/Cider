import Foundation
import SwiftUI
import AppKit

// Visual tokens lifted from the design handoff at
// chats/chat1.md + Wine Wrapper Configuration.html. We use SwiftUI/AppKit
// native controls but tint them to the design's dark-dialog palette.
enum DialogTheme {
    // Background / structure
    static let windowBg     = Color(nsColor: NSColor(srgbRed: 0.169, green: 0.169, blue: 0.180, alpha: 1.0))
    static let footerBgTop  = Color(nsColor: NSColor(srgbRed: 0.188, green: 0.188, blue: 0.200, alpha: 1.0))
    static let footerBgBot  = Color(nsColor: NSColor(srgbRed: 0.169, green: 0.169, blue: 0.180, alpha: 1.0))
    static let hairline     = Color.white.opacity(0.08)

    // Text
    static let text         = Color(nsColor: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.929, alpha: 1.0))
    static let textDim      = Color(nsColor: NSColor(srgbRed: 0.659, green: 0.659, blue: 0.678, alpha: 1.0))
    static let textMuted    = Color(nsColor: NSColor(srgbRed: 0.475, green: 0.475, blue: 0.494, alpha: 1.0))

    // Accents
    static let accent       = Color(nsColor: NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1.0))
    static let statusYellow = Color(nsColor: NSColor(srgbRed: 0.941, green: 0.706, blue: 0.000, alpha: 1.0))
    static let statusGreen  = Color(nsColor: NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1.0))

    // Inputs
    static let fieldBg          = Color(nsColor: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1.0))
    static let fieldBorder      = Color.white.opacity(0.10)

    // Spacing rhythm
    static let labelColumnWidth: CGFloat = 172
    static let rowGap: CGFloat           = 14
    static let sectionGap: CGFloat       = 26
    static let bodyHorizontal: CGFloat   = 28
    static let bodyTop: CGFloat          = 20
    static let bodyBottom: CGFloat       = 4
}

// Right-aligned dim section row label.
struct DialogRowLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DialogTheme.textDim)
            .frame(width: DialogTheme.labelColumnWidth, alignment: .trailing)
    }
}

// "—— LABEL ——" section header with hairline rules either side.
struct DialogSectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(DialogTheme.hairline)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(DialogTheme.textMuted)
            Rectangle()
                .fill(DialogTheme.hairline)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 14)
    }
}

// Dim 11.5pt help text shown beneath form rows.
struct DialogHelpText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(DialogTheme.textMuted)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// Dark, hairline-bordered text field matching the design's `.input` style.
struct DialogTextFieldStyle: TextFieldStyle {
    var monospaced: Bool = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(monospaced
                  ? .system(size: 12, design: .monospaced)
                  : .system(size: 13))
            .foregroundStyle(DialogTheme.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(DialogTheme.fieldBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(DialogTheme.fieldBorder, lineWidth: 0.5)
            )
    }
}

// Compact secondary button (Browse…).
struct DialogSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(DialogTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [
                            Color(nsColor: NSColor(srgbRed: 0.329, green: 0.329, blue: 0.345, alpha: 1.0)),
                            Color(nsColor: NSColor(srgbRed: 0.282, green: 0.282, blue: 0.298, alpha: 1.0))
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.78 : 1.0)
    }
}

// Filled blue primary button for Save.
struct DialogPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.55))
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [
                            Color(nsColor: NSColor(srgbRed: 0.310, green: 0.545, blue: 0.961, alpha: enabled ? 1.0 : 0.55)),
                            Color(nsColor: NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: enabled ? 1.0 : 0.55))
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed && enabled ? 0.85 : 1.0)
    }
}
