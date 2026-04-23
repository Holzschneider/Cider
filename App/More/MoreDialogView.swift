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
            Form {
                Section("Basic") {
                    TextField("Display name", text: $vm.displayName)
                    TextField("Executable (relative path)", text: $vm.exe,
                              prompt: Text("e.g. RagnarokPlus/ragnarok-plus-patcher.exe"))
                    TextField("Command-line args", text: $vm.argsText,
                              prompt: Text("e.g. /tui /log"))
                }

                Section("Source — where the Windows files live") {
                    Picker("Mode", selection: $vm.sourceMode) {
                        Text("Folder / .zip on disk").tag(CiderConfig.Source.Mode.path)
                        Text("Inside this bundle").tag(CiderConfig.Source.Mode.inBundle)
                        Text("URL (slim mode)").tag(CiderConfig.Source.Mode.url)
                    }
                    .pickerStyle(.segmented)

                    switch vm.sourceMode {
                    case .path:
                        pathPickerRow(label: "Path",
                                      text: $vm.sourcePath,
                                      placeholder: "/Users/.../MyGame or MyGame.zip",
                                      filter: .anyContent)
                    case .inBundle:
                        TextField("Sibling folder name",
                                  text: $vm.sourceInBundleFolder,
                                  prompt: Text("Game"))
                    case .url:
                        TextField("URL",
                                  text: $vm.sourceURL,
                                  prompt: Text("https://example.com/MyGame.zip"))
                        TextField("Expected SHA-256 (optional)",
                                  text: $vm.sourceSha256)
                    }
                }

                Section("Wine engine") {
                    TextField("Name", text: $vm.engineName,
                              prompt: Text("WS12WineCX24.0.7_7"))
                    TextField("Download URL", text: $vm.engineURL,
                              prompt: Text("https://github.com/Sikarugir-App/Engines/…"))
                    TextField("Expected SHA-256 (optional)", text: $vm.engineSha256)
                }

                Section("Graphics driver") {
                    Picker("", selection: $vm.graphics) {
                        ForEach(GraphicsDriverKind.allCases, id: \.self) { kind in
                            Text(label(for: kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Wine options") {
                    Toggle("MSYNC (Mach-port sync — recommended)", isOn: $vm.wineMsync)
                    Toggle("ESYNC (eventfd sync — recommended)", isOn: $vm.wineEsync)
                    Toggle("Wrap exe in cmd.exe (console / TUI apps)", isOn: $vm.wineConsole)
                    Toggle("Inherit cmd console (suppresses pop-up)", isOn: $vm.wineInheritConsole)
                        .disabled(!vm.wineConsole)
                    Toggle("Allow winedbg auto-attach (debug only)", isOn: $vm.wineUseWinedbg)
                    TextField("Winetricks verbs",
                              text: $vm.winetricksText,
                              prompt: Text("corefonts d3dx9 vcrun2019"))
                }

                Section("Presentation") {
                    pathPickerRow(label: "Splash",
                                  text: $vm.splashFile,
                                  placeholder: "splash.png",
                                  filter: .image)
                    Toggle("Splash has alpha (PNG, borderless transparent)",
                           isOn: $vm.splashTransparent)
                    pathPickerRow(label: "Icon",
                                  text: $vm.iconFile,
                                  placeholder: "icon.png or icon.icns",
                                  filter: .image)
                }

                Section("Storage") {
                    Toggle("Save cider.json inside the source folder",
                           isOn: $vm.storeInSourceFolder)
                    Text("Off (default): cider.json goes to ~/Library/Application Support/Cider/Configs/<bundle-name>.json. On: cider.json is written next to your source files so the folder is self-distributable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(vm.buildConfig()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.isValid)
            }
            .padding()
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 600, idealHeight: 720)
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

    private func pathPickerRow(
        label: String,
        text: Binding<String>,
        placeholder: String,
        filter: FilterKind
    ) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text(placeholder))
            Button("Browse…") {
                openPicker(into: text, filter: filter)
            }
            .buttonStyle(.bordered)
        }
    }

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
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
