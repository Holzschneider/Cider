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

// Right-aligned dim section row label, optionally preceded by a small
// red (!) marker pinned to the label's left side. The marker auto-shows
// a transient bubble (~3 s) when the error first appears or changes,
// re-shows on hover, and disappears otherwise. The marker + label sit
// inside the right-aligned label gutter so the layout doesn't shift
// when an error toggles on/off.
struct DialogRowLabel: View {
    let text: String
    var error: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            ErrorMarker(message: error)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DialogTheme.textDim)
        }
        .frame(width: DialogTheme.labelColumnWidth, alignment: .trailing)
    }
}

// Small (!) glyph that pops a red callout bubble to its left when the
// error first appears, again whenever the message changes, and on
// hover. Auto-hides ~3 s after the trigger if the cursor isn't over
// the glyph. Uses native NSPopover under the hood — only one bubble
// shows at a time across the whole window, which is fine for this
// dialog (a single visible bubble + the row's red glyph for any
// silent siblings reads as "fix these").
struct ErrorMarker: View {
    let message: String?

    @State private var isShowing: Bool = false
    @State private var hideTask: Task<Void, Never>?
    @State private var lastMessage: String? = nil
    @State private var isHovering: Bool = false

    private static let visibleSeconds: Double = 3.0

    var body: some View {
        Group {
            if let message {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12, weight: .regular))
                    .accessibilityLabel(message)
                    .onAppear {
                        triggerIfChanged(message)
                    }
                    .onChange(of: message) { newValue in
                        triggerIfChanged(newValue)
                    }
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            show(message: message)
                        } else {
                            scheduleHide()
                        }
                    }
                    .popover(isPresented: $isShowing, arrowEdge: .trailing) {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 280, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
            }
        }
    }

    private func triggerIfChanged(_ msg: String) {
        guard msg != lastMessage else { return }
        lastMessage = msg
        show(message: msg)
    }

    private func show(message: String) {
        hideTask?.cancel()
        if !isShowing { isShowing = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            // Stay open while the cursor sits on the glyph.
            if isHovering { return }
            isShowing = false
        }
        hideTask = task
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
