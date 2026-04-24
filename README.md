# Cider

Wrap a Windows app as a self-contained, double-clickable macOS `.app`
bundle backed by Wine.

Cider is **one notarizable `Cider.app`** that is both a GUI launcher *and*
a CLI tool. Drop a folder, `.zip`, `cider.json`, or a download URL onto
it; fill in the configuration form; click **Create…** to save a
configured copy elsewhere, or hold ⌥ for **Apply** (transform this
bundle in place). The result is a `.app` that — on every launch — shows
your splash, ensures the right Wine engine is downloaded, sets up a
prefix in `~/Library/Application Support/Cider/Prefixes/<name>/`, and
runs your Windows exe through Wine with all the env tweaks (MSYNC/ESYNC,
DXMT DLLs in both arches, etc.) that real-world games need.

## Status

End-to-end verified against the Sikarugir Wine engines using a 32-bit
Korean MMO patcher (RagnarokPlus). Schema v2 + the full GUI rewrite
have shipped. What's left for a public release is Xcode-project
migration + automated notarization (the build script + entitlements
plist are in place; pulling the trigger on `notarytool` is gated on a
$99 Apple Developer Program account).

92 unit + integration tests, including in-process HTTP downloads for
the URL source path and SIGTERM-on-cancel for the install-progress
sheet.

## How it works

The `.app` bundle is intentionally tiny — a single `cider` Mach-O plus
an `Info.plist`. **Where heavy state lives depends on the install mode
you picked in the More dialog:**

| Mode | Where the app's data sits | Where `cider.json` sits |
| --- | --- | --- |
| **Install** (default) | `~/Library/Application Support/Cider/Program Files/<name>/` | `…/Configs/<name>.json` |
| **Bundle** | `<bundle>/Application/` (sibling of `Contents/`) | `<bundle>/cider.json` (sibling of `Contents/`) |
| **Link** | wherever the user already keeps it (no copy) | `…/Configs/<name>.json`, with an absolute `applicationPath` |

`Bundle` mode is the distributable mode — the `.app` stays
self-contained and portable across disks/Macs. `Install` is the typical
"installed app" experience. `Link` is for "I want to keep developing
this game folder; just point Cider at it."

Wine engines, wrapper templates, and prefixes are always shared in
`~/Library/Application Support/Cider/`:

| Lives in | What |
| --- | --- |
| `…/Engines/` | Sikarugir Wine engines, shared across configured `.app`s |
| `…/Templates/` | Sikarugir wrapper templates (libinotify, libgnutls, MoltenVK, renderer DLLs) |
| `…/Prefixes/<name>/` | The Wine prefix per app |
| `…/RuntimeStats/<name>.json` | Rolling stats for the splash's load-progress bar + future patcher hashes |
| `…/Cache/Downloads/` | Downloaded zip / cider.json payloads from URL sources |

The bundle's name (`Bundle.main.bundleURL.deletingPathExtension()
.lastPathComponent`) is the AppSupport key — renaming the bundle =
pointing it at a different config / prefix / stats slot. The orchestrator
moves AppSupport assets along with the bundle when you change
**Application Name** in the More dialog (Phase 10 rename-on-Save).

A bundle in **Bundle** mode places `cider.json` directly next to
`Contents/`. That sibling location is outside the codesign seal and
notarization ticket, so a distributor can ship a fully self-contained
`.app` without breaking either.

## Configuration (`cider.json`, schema v2)

```json
{
  "schemaVersion": 2,
  "displayName": "My Game",
  "applicationPath": "Application",
  "exe": "MyGame/Game.exe",
  "args": ["/tui", "/log"],
  "engine": {
    "name": "WS12WineCX24.0.7_7",
    "url": "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz"
  },
  "wrapperTemplate": {
    "version": "1.0.11",
    "url": "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
  },
  "graphics": "dxmt",
  "wine": {
    "esync": true, "msync": true,
    "console": true, "inheritConsole": false,
    "useWinedbg": false, "winetricks": []
  },
  "splash": { "file": "splash.png", "transparent": true },
  "icon": "icon.icns",
  "originURL": "https://example.org/cider.json",
  "distributionURL": "https://example.org/MyGame.zip"
}
```

`applicationPath` is resolved relative to the directory `cider.json`
itself lives in:

- absolute path → **Link** mode (run the app in place from there)
- `"Application"` or `"Application/…"` → **Bundle** mode (data inside the
  `.app` bundle)
- any other relative path → **Install** mode (data under
  `AppSupport/Program Files/<name>/`)

`originURL` and `distributionURL` are optional. They get filled in
automatically when the user drops a remote URL: `originURL` records
where the dropped `cider.json` came from (if any), `distributionURL`
records where the data zip came from. Both are reserved for a future
"check for updates" affordance.

## URL sources

You can drop or paste an `http(s)://` URL onto the drop zone. Cider
HEADs it to disambiguate via `Content-Type` (with extension fallback):

- **Zip** → downloaded to `AppSupport/Cache/Downloads/`, treated as a
  local zip from there.
- **`cider.json`** → fetched, parsed, used to pre-fill the More dialog;
  its `distributionURL` is followed to download the actual zip.

Drag from a browser, or `Cmd+V` while the drop zone has focus.

## Build

The build system is Swift Package Manager.

```sh
swift build -c release            # build the cider Mach-O
./scripts/build-app.sh            # wrap it into a signed Cider.app
swift test                        # run the test suite
```

`build-app.sh` produces an ad-hoc-signed `./build/Cider.app` with the
hardened-runtime entitlements that wine + DXMT/MoltenVK need.

For Developer ID + notarization (after you have an Apple Developer
account and a `notarytool` keychain profile set up):

```sh
./scripts/sign-and-notarize.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --keychain-profile "AC_PASSWORD"
```

See `scripts/sign-and-notarize.sh --help` for prereqs.

## CLI surface

```
cider                               # GUI: drop zone (no config) or splash (configured)
cider apply       --config <path>   # in-place transmogrify, set custom icon, persist config
cider clone       --to <path> ...   # save a configured copy
cider config show                   # print the resolved cider.json
cider engines list                  # what's cached under AppSupport/Engines/
cider engines pull <name>           # download an engine
cider launch                        # (diagnostic) run the LaunchPipeline headlessly
cider preview-splash --image <p>    # (diagnostic) open the splash window only
```

## Layout

```
.
├── App/                        # SwiftUI / AppKit GUI + CLI router
│   ├── CiderApp.swift              # @main entry; dispatches CLI vs GUI
│   ├── BundleEnvironment.swift     # bundle URL / name / writability
│   ├── AppShell.swift              # shared NSApplication + menu-bar setup
│   ├── CLI/                        # ArgumentParser subcommands
│   ├── DropZone/                   # vanilla-bundle drag-drop window + Apply/Create orchestrator
│   ├── More/                       # SwiftUI configuration form (install-mode picker, per-field errors)
│   ├── Progress/                   # modal install-progress sheet (cancellable)
│   └── Splash/                     # borderless transparent splash + load-progress overlay
├── Core/
│   ├── Installer.swift             # materialises sources for Install / Bundle / Link
│   ├── URLSourceResolver.swift     # HEAD-based zip / cider.json disambiguation
│   ├── SourceAcquisition.swift     # what was dropped (folder / zip / URL)
│   ├── BundleTransmogrifier.swift  # bundle rename + clone + custom icon (CLI)
│   ├── EngineManager.swift         ├── TemplateManager.swift
│   ├── GraphicsDriver.swift        ├── PrefixInitializer.swift
│   ├── WineLauncher.swift          ├── ConsoleLineCounter.swift
│   ├── LaunchPipeline.swift
│   ├── IconConverter.swift         ├── Downloader.swift
│   ├── IntegrityChecker.swift      ├── ConfigStore.swift
│   ├── AppSupport.swift            ├── Logger.swift
│   └── Shell.swift                 # sync + cancellable async runners
├── Models/                     # CiderConfig (schema v2) + CiderRuntimeStats
├── Resources/Cider.entitlements    # hardened-runtime entitlements
├── scripts/
│   ├── build-app.sh                # SPM build → signed Cider.app
│   └── sign-and-notarize.sh        # Developer ID + notarytool + stapler
├── Tests/CiderTests/           # 92 XCTest cases
├── Package.swift
└── README.md
```

## Acknowledgements

- [Sikarugir-App](https://github.com/Sikarugir-App) for the prebuilt
  Wine engines + wrapper templates Cider depends on.
- [3Shain/dxmt](https://github.com/3Shain/dxmt), CrossOver/D3DMetal,
  [doitsujin/dxvk](https://github.com/doitsujin/dxvk) for the graphics
  translation layers.
- [Whisky](https://github.com/Whisky-App/Whisky) and Kegworks for the
  reference designs.
