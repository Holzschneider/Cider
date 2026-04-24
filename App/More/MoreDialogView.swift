import Foundation
import SwiftUI
import AppKit
import CiderModels

struct MoreDialogView: View {
    @ObservedObject var vm: MoreDialogViewModel
    var onCancel: () -> Void
    var onSave: (CiderConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basicSection
                    sourceSection
                    engineSection
                    graphicsSection
                    wineSection
                    presentationSection
                    storageSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(vm.buildConfig()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.isValid)
            }
            .padding(16)
        }
    }

    // MARK: - Sections

    private var basicSection: some View {
        section("Basic") {
            labeledRow("Display name") {
                TextField("", text: $vm.displayName,
                          prompt: Text("e.g. RagnarokPlus"))
            }
            labeledRow("Executable") {
                TextField("", text: $vm.exe,
                          prompt: Text("RagnarokPlus/ragnarok-plus-patcher.exe"))
            }
            labeledRow("Arguments") {
                TextField("", text: $vm.argsText,
                          prompt: Text("/tui /log"))
            }
        }
    }

    private var sourceSection: some View {
        section("Source") {
            labeledRow("Mode") {
                Picker("", selection: $vm.sourceMode) {
                    Text("Folder / .zip").tag(CiderConfig.Source.Mode.path)
                    Text("In bundle").tag(CiderConfig.Source.Mode.inBundle)
                    Text("URL (slim)").tag(CiderConfig.Source.Mode.url)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch vm.sourceMode {
            case .path:
                labeledRow("Path") {
                    pathPicker(text: $vm.sourcePath,
                               placeholder: "/Users/.../MyGame or MyGame.zip",
                               filter: .anyContent)
                }
            case .inBundle:
                labeledRow("Folder name") {
                    TextField("", text: $vm.sourceInBundleFolder,
                              prompt: Text("Game"))
                }
            case .url:
                labeledRow("URL") {
                    TextField("", text: $vm.sourceURL,
                              prompt: Text("https://example.com/MyGame.zip"))
                }
                labeledRow("SHA-256") {
                    TextField("", text: $vm.sourceSha256,
                              prompt: Text("(optional)"))
                }
            }
        }
    }

    private var engineSection: some View {
        section("Wine engine") {
            labeledRow("Name") {
                TextField("", text: $vm.engineName,
                          prompt: Text("WS12WineCX24.0.7_7"))
            }
            labeledRow("URL") {
                TextField("", text: $vm.engineURL,
                          prompt: Text("https://github.com/Sikarugir-App/Engines/…"))
            }
            labeledRow("SHA-256") {
                TextField("", text: $vm.engineSha256,
                          prompt: Text("(optional)"))
            }
        }
    }

    private var graphicsSection: some View {
        section("Graphics driver") {
            Picker("", selection: $vm.graphics) {
                ForEach(GraphicsDriverKind.allCases, id: \.self) { kind in
                    Text(label(for: kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var wineSection: some View {
        section("Wine options") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("MSYNC (Mach-port sync)", isOn: $vm.wineMsync)
                Toggle("ESYNC (eventfd sync)", isOn: $vm.wineEsync)
                Toggle("Wrap exe in cmd.exe (console / TUI apps)", isOn: $vm.wineConsole)
                Toggle("Inherit cmd console (suppresses pop-up)", isOn: $vm.wineInheritConsole)
                    .disabled(!vm.wineConsole)
                    .padding(.leading, 18)
                Toggle("Allow winedbg auto-attach (debug only)", isOn: $vm.wineUseWinedbg)
            }
            labeledRow("Winetricks") {
                TextField("", text: $vm.winetricksText,
                          prompt: Text("corefonts d3dx9 vcrun2019"))
            }
        }
    }

    private var presentationSection: some View {
        section("Presentation") {
            labeledRow("Splash") {
                pathPicker(text: $vm.splashFile,
                           placeholder: "splash.png",
                           filter: .image)
            }
            Toggle("Splash has alpha (PNG, borderless transparent)",
                   isOn: $vm.splashTransparent)
            labeledRow("Icon") {
                pathPicker(text: $vm.iconFile,
                           placeholder: "icon.png or icon.icns",
                           filter: .image)
            }
        }
    }

    private var storageSection: some View {
        section("Storage") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Save cider.json inside the source folder",
                       isOn: $vm.storeInSourceFolder)
                Text("""
                    Off (default): writes to ~/Library/Application Support/Cider/Configs/<bundle-name>.json.
                    On: writes next to your source files so the source folder is self-distributable.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledRow<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            field()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pathPicker(
        text: Binding<String>,
        placeholder: String,
        filter: FilterKind
    ) -> some View {
        HStack(spacing: 6) {
            TextField("", text: text, prompt: Text(placeholder))
            Button("Browse…") {
                openPicker(into: text, filter: filter)
            }
            .buttonStyle(.bordered)
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

    // NSOpenPanel.runModal collides with the outer NSApp.runModal(for:)
    // session that hosts MoreDialog (the picker doesn't appear until the
    // outer modal ends). Attach as a sheet to the key window instead so
    // the panel runs inside the existing modal session.
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
            // Fallback when no key window — runModal works fine if there's
            // no outer modal session.
            if panel.runModal() == .OK, let url = panel.url {
                binding.wrappedValue = url.path
            }
        }
    }
}
