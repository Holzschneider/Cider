import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CiderModels
import CiderCore

// Implements the design from cider-settings-dialog/project/Wine Wrapper
// Configuration.html — macOS-y dark dialog, 620pt wide, 172pt right-aligned
// label gutter, 14pt row gap, 26pt section gap, sections rendered as
// `bar | LABEL | bar` with hairline dividers, footer with status dot.
struct MoreDialogView: View {
    @ObservedObject var vm: MoreDialogViewModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DialogTheme.sectionGap) {
                    if let err = vm.generalError {
                        generalErrorBanner(err)
                    }
                    basicSection
                    sourceSection
                    engineSection
                    graphicsSection
                    wineOptionsSection
                    presentationSection
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

    // MARK: - Banner

    private func generalErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16, weight: .regular))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last attempt failed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DialogTheme.text)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(DialogTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: 0.75)
        )
    }


    // MARK: - Sections

    private var basicSection: some View {
        section("Basic") {
            row("Application Name", error: vm.displayNameError) {
                TextField("My Windows Game", text: $vm.displayName)
                    .textFieldStyle(DialogTextFieldStyle())
            }
            row("Executable", error: vm.exeError) {
                HStack(spacing: 8) {
                    TextField("Game.exe", text: $vm.exe)
                        .textFieldStyle(DialogTextFieldStyle(monospaced: true))
                    if let source = vm.sourceForBrowsing {
                        Button("Browse…") { browseForExecutable(in: source) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            row("Command-line args") {
                TextField("/option /switch", text: $vm.argsText)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var sourceSection: some View {
        section("Application") {
            row("Install mode", help: installModeHelp) {
                Picker("", selection: $vm.installMode) {
                    Text("Install").tag(InstallMode.install)
                    Text("Bundle").tag(InstallMode.bundle)
                    Text("Link").tag(InstallMode.link)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            row("Source", help: sourceFieldHelp, error: vm.sourceError) {
                pathPicker(text: $vm.sourcePath,
                           placeholder: sourceFieldPlaceholder,
                           filter: vm.installMode == .link ? .folderOnly : .anyContent)
            }
            if vm.installMode != .link
               && !vm.applicationPath.trimmingCharacters(in: .whitespaces).isEmpty {
                row(" ") {
                    Text("Already installed at: \(vm.applicationPath)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DialogTheme.textMuted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            row("Origin URL", help: "Optional — set automatically when a remote cider.json was dropped.") {
                TextField("(none)", text: $vm.originURL)
                    .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            }
        }
    }

    private var installModeHelp: String {
        switch vm.installMode {
        case .install:
            // Mirror what the orchestrator actually uses for the
            // AppSupport slot: the sanitised Application Name.
            let sanitised = BundleTransmogrifier.sanitiseBundleName(vm.displayName)
            let slot = sanitised.isEmpty ? "<Application Name>" : sanitised
            return "Copy the source into ~/Library/Application Support/Cider/Program Files/\(slot)/. The .app bundle stays small."
        case .bundle:
            return "Copy the source inside the .app bundle (sibling of Contents/). Bundle stays self-contained and portable."
        case .link:
            return "Run the app from where it sits — no copy. cider.json records an absolute path to the source folder."
        }
    }

    private var sourceFieldHelp: String {
        switch vm.installMode {
        case .install, .bundle:
            return "Folder, .zip, or http(s):// URL. URLs may point at a zip directly or at a cider.json that references one."
        case .link:
            return "Absolute path to the existing folder Cider should run in place."
        }
    }

    private var sourceFieldPlaceholder: String {
        switch vm.installMode {
        case .install, .bundle:
            return "/path/to/folder, /path/to/game.zip, or https://…/game.zip"
        case .link:
            return "/Users/me/Games/MyGame"
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
            row("Name", error: vm.engineNameError) {
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
                TextField("corefonts vcrun2019", text: $vm.winetricksText)
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
            row("App icon",
                help: "PNG / JPEG / Windows .ico / .icns. Picking a file inside the source folder writes a relative path; anything outside writes an absolute path.") {
                iconPathPicker(text: $vm.iconFile,
                               placeholder: "icon.png, icon.ico, or icon.icns")
            }
        }
    }

    private func iconPathPicker(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(DialogTextFieldStyle(monospaced: true))
            Button("Browse…") {
                chooseIcon(into: text)
            }
            .buttonStyle(.bordered)
        }
    }

    private func chooseIcon(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.png, .jpeg, .icns]
        if let ico = UTType("com.microsoft.ico") {
            types.append(ico)
        }
        panel.allowedContentTypes = types

        // Root the panel inside the source folder when possible — the
        // icon usually ships alongside the game files.
        let sourceFolder: URL? = {
            if case .folder(let folder) = vm.sourceAcquisition { return folder }
            return vm.sourceForBrowsing
        }()
        if let folder = sourceFolder {
            panel.directoryURL = folder
        }

        let pick: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let picked = panel.url else { return }
            if let folder = sourceFolder,
               let rel = relativePath(of: picked, under: folder) {
                binding.wrappedValue = rel
            } else {
                binding.wrappedValue = picked.path
            }
        }
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent, completionHandler: pick)
        } else {
            pick(panel.runModal())
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
                Button("Save") { onSave() }
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
        // First user-facing field error wins the pill text. Keeps the
        // footer summary in sync with the inline red ! markers above.
        let (label, dot): (String, Color)
        if vm.isValid {
            label = "Ready to save"
            dot = DialogTheme.statusGreen
        } else {
            let firstError = vm.displayNameError
                ?? vm.exeError
                ?? vm.sourceError
                ?? vm.engineNameError
                ?? vm.engineURLError
                ?? "Fill in the highlighted fields to continue"
            label = firstError
            dot = DialogTheme.statusYellow
        }
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
                .lineLimit(2)
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
        error: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        // Baseline-align so the label sits on the same line as the
        // field/button instead of vertically centering between the
        // field and the help text below it.
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            DialogRowLabel(text: label, error: error)
            VStack(alignment: .leading, spacing: 6) {
                field()
                // The error message lives in the marker's tooltip
                // (see ErrorMarker) — only the help text shows under
                // the field, when there's no error competing for
                // attention.
                if error == nil, let help {
                    DialogHelpText(text: help)
                }
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
        case folderOnly
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
            // Accept .ico in addition to the macOS-native formats so
            // distributors can drop in the icon shipped with the
            // Windows app directly.
            var types: [UTType] = [.png, .jpeg, .icns]
            if let ico = UTType("com.microsoft.ico") {
                types.append(ico)
            }
            panel.allowedContentTypes = types
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
        case .anyContent:
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
        case .folderOnly:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
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
