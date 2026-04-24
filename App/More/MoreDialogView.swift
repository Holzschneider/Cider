import Foundation
import SwiftUI
import AppKit
import CiderModels

// Implements the design from cider-settings-dialog/project/Wine Wrapper
// Configuration.html — macOS-y dark dialog, 620pt wide, 172pt right-aligned
// label gutter, 14pt row gap, 26pt section gap, sections rendered as
// `bar | LABEL | bar` with hairline dividers, footer with status dot.
struct MoreDialogView: View {
    @ObservedObject var vm: MoreDialogViewModel
    var onCancel: () -> Void
    var onSave: (CiderConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DialogTheme.sectionGap) {
                    basicSection
                    sourceSection
                    engineSection
                    graphicsSection
                    wineOptionsSection
                    presentationSection
                    storageSection
                }
                .padding(.top, DialogTheme.bodyTop)
                .padding(.bottom, DialogTheme.bodyBottom)
                .padding(.horizontal, DialogTheme.bodyHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DialogTheme.windowBg)

            footer
        }
        .background(DialogTheme.windowBg)
    }

    // MARK: - Sections

    private var basicSection: some View {
        section("Basic") {
            row("Display name") {
                TextField("My Windows Game", text: $vm.displayName)
                    .textFieldStyle(DialogTextFieldStyle())
            }
            row("Executable") {
                TextField("RagnarokPlus/ragnarok-plus-patcher.exe", text: $vm.exe)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
            row("Command-line args") {
                TextField("/tui /log", text: $vm.argsText)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var sourceSection: some View {
        section("Source") {
            row("Mode", help: "Where the Windows files live.") {
                Picker("", selection: $vm.sourceMode) {
                    Text("Folder / .zip on disk").tag(CiderConfig.Source.Mode.path)
                    Text("Inside this bundle").tag(CiderConfig.Source.Mode.inBundle)
                    Text("URL (slim mode)").tag(CiderConfig.Source.Mode.url)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch vm.sourceMode {
            case .path:
                row("Path") {
                    pathPicker(text: $vm.sourcePath,
                               placeholder: "/Users/me/Games/MyGame or MyGame.zip",
                               filter: .anyContent)
                }
            case .inBundle:
                row("Folder") {
                    TextField("Game", text: $vm.sourceInBundleFolder)
                        .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                }
            case .url:
                row("URL") {
                    TextField("https://example.org/game.zip", text: $vm.sourceURL)
                        .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                }
                row("Expected SHA-256", help: "Optional — verifies the download.") {
                    TextField("e3b0c442… (64 hex chars)", text: $vm.sourceSha256)
                        .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                }
            }
        }
    }

    private var engineSection: some View {
        section("Wine engine") {
            row("Name") {
                TextField("WS12WineCX24.0.7_7", text: $vm.engineName)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
            row("Download URL") {
                TextField("https://github.com/Sikarugir-App/Engines/…", text: $vm.engineURL)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
            row("Expected SHA-256", help: "Optional — verifies the download.") {
                TextField("e3b0c442… (64 hex chars)", text: $vm.engineSha256)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var graphicsSection: some View {
        section("Graphics driver") {
            row("Translator",
                help: "Translates Direct3D calls to Metal. D3DMetal is the most compatible on recent macOS.") {
                Picker("", selection: $vm.graphics) {
                    ForEach(GraphicsDriverKind.allCases, id: \.self) { kind in
                        Text(label(for: kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var wineOptionsSection: some View {
        section("Wine options") {
            rowTopAligned("Sync & runtime") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    Toggle(isOn: $vm.wineMsync) {
                        toggleLabel("MSYNC", muted: " — Mach-port sync (recommended)")
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $vm.wineEsync) {
                        toggleLabel("ESYNC", muted: " — eventfd sync (recommended)")
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $vm.wineConsole) {
                        toggleStackedLabel(
                            primary: "Wrap .exe in cmd.exe",
                            secondary: "Console / TUI apps")
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $vm.wineInheritConsole) {
                        toggleStackedLabel(
                            primary: "Inherit cmd console",
                            secondary: "Suppresses the popup window")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!vm.wineConsole)

                    Toggle(isOn: $vm.wineUseWinedbg) {
                        toggleStackedLabel(
                            primary: "Allow winedbg auto-attach",
                            secondary: "Debug builds only")
                    }
                    .toggleStyle(.checkbox)
                }
            }

            row("Winetricks verbs", help: "Space-separated. Installed once on first launch.") {
                TextField("corefonts d3dx9 vcrun2019", text: $vm.winetricksText)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var presentationSection: some View {
        section("Presentation") {
            row("Splash image") {
                pathPicker(text: $vm.splashFile,
                           placeholder: "splash.png",
                           filter: .image)
            }
            row(" ") {
                Toggle(isOn: $vm.splashTransparent) {
                    toggleLabel("Splash has alpha", muted: " (PNG, borderless transparent)")
                }
                .toggleStyle(.checkbox)
            }
            row("App icon") {
                pathPicker(text: $vm.iconFile,
                           placeholder: "icon.png or icon.icns",
                           filter: .image)
            }
        }
    }

    private var storageSection: some View {
        section("Storage") {
            rowTopAligned(" ", help: "Off (default): config goes to ~/Library/Application Support/Cider/Configs/<bundle-name>.json.") {
                Toggle(isOn: $vm.storeInSourceFolder) {
                    toggleLabel("Save", muted: " cider.json inside the source folder")
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DialogTheme.hairline).frame(height: 0.5)
            HStack(spacing: 10) {
                statusPill
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DialogSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(vm.buildConfig()) }
                    .buttonStyle(DialogPrimaryButtonStyle(enabled: vm.isValid))
                    .disabled(!vm.isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [DialogTheme.footerBgTop, DialogTheme.footerBgBot],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    private var statusPill: some View {
        let (label, dot): (String, Color) = vm.isValid
            ? ("Ready to save", DialogTheme.statusGreen)
            : ("Fill in display name and source to continue", DialogTheme.statusYellow)
        return HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .strokeBorder(dot.opacity(0.35), lineWidth: 2)
                        .scaleEffect(2)
                )
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DialogTheme.textMuted)
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogSectionHeader(title: title)
            VStack(alignment: .leading, spacing: DialogTheme.rowGap) {
                content()
            }
        }
    }

    @ViewBuilder
    private func row<Field: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            DialogRowLabel(text: label)
            VStack(alignment: .leading, spacing: 6) {
                field()
                if let help { DialogHelpText(text: help) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // For rows whose field is taller than a single row (e.g. a grid of
    // checkboxes), align the label to the top.
    @ViewBuilder
    private func rowTopAligned<Field: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            DialogRowLabel(text: label)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                field()
                if let help { DialogHelpText(text: help) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Misc

    @ViewBuilder
    private func toggleLabel(_ primary: String, muted: String) -> some View {
        (Text(primary).foregroundColor(DialogTheme.text)
         + Text(muted).foregroundColor(DialogTheme.textMuted))
            .font(.system(size: 13))
    }

    @ViewBuilder
    private func toggleStackedLabel(primary: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(.system(size: 13))
                .foregroundStyle(DialogTheme.text)
            Text(secondary)
                .font(.system(size: 11.5))
                .foregroundStyle(DialogTheme.textMuted)
        }
    }

    private func label(for kind: GraphicsDriverKind) -> String {
        switch kind {
        case .dxmt:     return "DXMT"
        case .d3dmetal: return "D3DMetal"
        case .dxvk:     return "DXVK"
        }
    }

    enum FilterKind {
        case image
        case anyContent
    }

    private func pathPicker(text: Binding<String>, placeholder: String, filter: FilterKind) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            Button("Browse…") {
                openPicker(into: text, filter: filter)
            }
            .buttonStyle(DialogSecondaryButtonStyle())
        }
    }

    // Sheet attached to the key (More) window so the panel runs inside the
    // outer NSApp.runModal session — see MoreDialogController for why.
    private func openPicker(into binding: Binding<String>, filter: FilterKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch filter {
        case .image:
            panel.allowedContentTypes = [.png, .jpeg, .icns]
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
        case .anyContent:
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
        }
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent) { response in
                if response == .OK, let url = panel.url {
                    binding.wrappedValue = url.path
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                binding.wrappedValue = url.path
            }
        }
    }
}
