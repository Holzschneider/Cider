import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @ObservedObject var vm: DropZoneViewModel
    @State private var hovering: Bool = false

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
                        vm.cloneAndApply?()
                    } else {
                        vm.apply?()
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

            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                if vm.dropped == .none {
                    Text("Drop a folder, .zip, or cider.json")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    Text(vm.dropped.displayLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Click More… to edit, then Apply.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $hovering) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    vm.handleDrop(url)
                }
            }
            return true
        }
        // SwiftUI's load via NSItemProvider sometimes reads the URL in a
        // background queue; the .onDrop closure must dispatch to main.
    }
}

// SwiftUI doesn't yet expose modifierFlag changes ergonomically; we feed
// option-key state in from the AppKit layer (see DropZoneController which
// installs an NSEvent.addLocalMonitorForEvents handler).
