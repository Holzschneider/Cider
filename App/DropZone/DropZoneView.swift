import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @ObservedObject var vm: DropZoneViewModel
    @State private var hovering: Bool = false           // dragging over the drop zone
    @State private var sourceHovering: Bool = false     // pointer over the dropped source

    var body: some View {
        VStack(spacing: 18) {
            Text("Cider")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 6)

            Text("Wrap a Windows app as a macOS .app via Wine.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            dropArea
                .frame(maxWidth: .infinity, minHeight: 180)

            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Button("More…") {
                    vm.openMoreDialog?(vm.loadedConfig, vm.dropped)
                }
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button(vm.primaryButtonLabel) {
                    if vm.isOptionPressed {
                        vm.applyInPlace?()
                    } else {
                        vm.create?()
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!vm.canApply)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(hovering ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if let url = vm.dropped.sourceURL {
                droppedContent(url: url)
            } else {
                emptyContent
            }
        }
        .onDrop(of: [UTType.fileURL.identifier,
                     UTType.url.identifier,
                     UTType.plainText.identifier],
                isTargeted: $hovering) { providers in
            guard let provider = providers.first else { return false }
            // File URLs come through fileURL; web URLs (Safari drag, etc.)
            // arrive as UTType.url; pasted text drags arrive as plainText.
            // Try fileURL first, then URL.self (covers both file and web),
            // then plain text parsed as a URL.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in vm.handleDrop(url) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in vm.handleDrop(url) }
                }
                return true
            }
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String,
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { return }
                Task { @MainActor in vm.handleDrop(url) }
            }
            return true
        }
        .onPasteCommand(of: [UTType.url.identifier, UTType.plainText.identifier]) { providers in
            guard let provider = providers.first else { return }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in vm.handleDrop(url) }
                }
                return
            }
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String,
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { return }
                Task { @MainActor in vm.handleDrop(url) }
            }
        }
        // SwiftUI's load via NSItemProvider sometimes reads the URL in a
        // background queue; the .onDrop closure must dispatch to main.
    }

    private var emptyContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a folder, .zip, cider.json, or a URL")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func droppedContent(url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Double-click to clear")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(sourceHovering ? 1 : 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { sourceHovering = $0 }
            .onTapGesture(count: 2) { vm.clearSource() }

            if sourceHovering {
                Button(action: { vm.clearSource() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Clear")
                .padding(8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: sourceHovering)
    }
}

// SwiftUI doesn't yet expose modifierFlag changes ergonomically; we feed
// option-key state in from the AppKit layer (see DropZoneController which
// installs an NSEvent.addLocalMonitorForEvents handler).
