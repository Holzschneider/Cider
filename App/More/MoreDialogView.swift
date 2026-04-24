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
                    // Storage section removed in Phase 1 — Phase 6 reintroduces
                    // it as the install-mode picker (Install / Bundle / Link).
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
                HStack(spacing: 8) {
                    TextField("RagnarokPlus/ragnarok-plus-patcher.exe", text: $vm.exe)
                        .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                    if let source = vm.sourceForBrowsing {
                        Button("Browse…") { browseForExecutable(in: source) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            row("Command-line args") {
                TextField("/tui /log", text: $vm.argsText)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var sourceSection: some View {
        section("Application") {
            row("Path",
                help: "Absolute path → Link mode (run in place). Relative → resolved against the cider.json's location (Install or Bundle mode). Phase 6 turns this into the proper install-mode picker.") {
                pathPicker(text: $vm.applicationPath,
                           placeholder: "/Users/me/Games/MyGame",
                           filter: .anyContent)
            }
            row("Origin URL", help: "Optional — set automatically when a remote cider.json was dropped.") {
                TextField("(none)", text: $vm.originURL)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var engineSection: some View {
        section("Wine engine") {
            row("Custom Repository") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $vm.useCustomRepository)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .onChange(of: vm.useCustomRepository) { _ in
                            vm.refreshEngineCatalog()
                        }
                    if vm.useCustomRepository {
                        TextField(EngineCatalog.defaultRepositoryPageURL,
                                  text: $vm.customRepositoryURL)
                            .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                            .onSubmit { vm.refreshEngineCatalog() }
                    } else {
                        // Read-only display of the default catalog URL.
                        Text(EngineCatalog.defaultRepositoryPageURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DialogTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(DialogTheme.fieldBg.opacity(0.55))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(DialogTheme.fieldBorder, lineWidth: 0.5)
                            )
                    }
                }
            }
            row("Name") {
                HStack(spacing: 8) {
                    EditableComboBox(
                        text: $vm.engineName,
                        items: vm.availableEngines.map(\.name),
                        placeholder: "WS12WineCX24.0.7_7"
                    )
                    .frame(height: 24)
                    .onChange(of: vm.engineName) { newName in
                        // When the user picks a catalog entry, update the
                        // download URL alongside it.
                        if let entry = vm.availableEngines.first(where: { $0.name == newName }) {
                            vm.engineURL = entry.downloadURL
                        }
                    }
                    if vm.isFetchingEngines {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 16, height: 16)
                    }
                }
            }
            if let err = vm.catalogError {
                row(" ") {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }
            row("Expected SHA-256", help: "Optional — verifies the download.") {
                TextField("e3b0c442… (64 hex chars)", text: $vm.engineSha256)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
        .onAppear { vm.refreshEngineCatalog(initial: true) }
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

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DialogTheme.hairline).frame(height: 0.5)
            HStack(spacing: 10) {
                statusPill
                Spacer()
                // Native styles here — custom ButtonStyle wrappers were
                // interfering with the Button's hit-area inside an
                // NSApp.runModal context, leaving the buttons rendered
                // but unresponsive. The native .bordered / .borderedProminent
                // tints to the .accent we set on the dark window so it
                // still reads as the design's dark dialog.
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(vm.buildConfig()) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Executable picker

    private func browseForExecutable(in source: URL) {
        if source.pathExtension.lowercased() == "zip" {
            chooseExeFromZip(source)
        } else {
            chooseExeFromFolder(source)
        }
    }

    private func chooseExeFromFolder(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "Choose the Windows executable inside \(folder.lastPathComponent)."
        panel.prompt = "Choose"
        let pick: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let picked = panel.url else { return }
            vm.exe = relativePath(of: picked, under: folder) ?? picked.path
        }
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent, completionHandler: pick)
        } else {
            pick(panel.runModal())
        }
    }

    // Lists .exe entries inside the zip via `unzip -l`, presents an
    // NSAlert with a popup so the user can pick one without extracting.
    private func chooseExeFromZip(_ zip: URL) {
        let exes = listExecutablesInZip(zip)
        guard !exes.isEmpty else {
            let warn = NSAlert()
            warn.messageText = "No .exe files found in \(zip.lastPathComponent)"
            warn.informativeText = "Type the path manually if your executable has an unusual extension."
            warn.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose executable"
        alert.informativeText = "From \(zip.lastPathComponent)"
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        popup.addItems(withTitles: exes)
        alert.accessoryView = popup
        if alert.runModal() == .alertFirstButtonReturn {
            vm.exe = popup.titleOfSelectedItem ?? vm.exe
        }
    }

    private func listExecutablesInZip(_ zip: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var results: [String] = []
        for line in text.split(separator: "\n") {
            // Lines look like:
            //   "    12345  2024-01-01 12:00   path/to/file.exe"
            // The filename is everything after the time column. Splitting
            // by whitespace and reassembling from index 3 keeps spaces in
            // filenames intact.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            let path = parts.dropFirst(3).joined(separator: " ")
            if path.lowercased().hasSuffix(".exe") {
                results.append(path)
            }
        }
        return results.sorted()
    }

    // Returns "Foo/Bar.exe" for picked = base/Foo/Bar.exe.
    private func relativePath(of picked: URL, under base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let pickedPath = picked.standardizedFileURL.path
        guard pickedPath.hasPrefix(basePath + "/") else { return nil }
        return String(pickedPath.dropFirst(basePath.count + 1))
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
