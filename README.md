# Cider

Wrap a Windows app as a self-contained, double-clickable macOS `.app`
bundle backed by Wine.

Cider is **one notarizable `Cider.app`** that is both a GUI launcher *and*
a CLI tool. Drop a folder, `.zip`, or `cider.json` onto it; fill in the
configuration form; click **Apply** (rename this bundle in place) or
hold ⌥ for **Clone & Apply…** (save a configured copy elsewhere). The
result is a `.app` that — on every launch — shows your splash, ensures
the right Wine engine is downloaded, sets up a prefix in
`~/Library/Application Support/Cider/Prefixes/<name>/`, and runs your
Windows exe through Wine with all the env tweaks (MSYNC/ESYNC, DXMT
DLLs in both arches, etc.) that real-world games need.

## Status

Architecture: in-place GUI rewrite. **10/11 planned phases shipped**.
End-to-end verified against the Sikarugir Wine engines using a 32-bit
Korean MMO patcher (RagnarokPlus). What's left is full Xcode-project
migration + automated notarization (the build script + entitlements
plist are in place; pulling the trigger on `notarytool` is gated on a
$99 Apple Developer Program account).

## How it works

The `.app` bundle is intentionally tiny — a single `cider` Mach-O plus
an `Info.plist`. **All heavy state lives outside `Contents/`:**

| Lives in | What |
| --- | --- |
| `~/Library/Application Support/Cider/Engines/` | Sikarugir Wine engines, shared across configured `.app`s |
| `…/Templates/` | Sikarugir wrapper templates (libinotify, libgnutls, MoltenVK, renderer DLLs) |
| `…/Prefixes/<bundle-name>/` | The Wine prefix per game |
| `…/Configs/<bundle-name>.json` | The per-bundle `cider.json` (default) |
| `…/RuntimeStats/<bundle-name>.json` | Rolling stats for the splash's load-progress bar + slim-mode patcher hashes |
| `…/Cache/Downloads/` | Slim-mode (URL) source payloads |

The bundle's name (`Bundle.main.bundleURL.deletingPathExtension()
.lastPathComponent`) is the key tying it to its config / prefix /
stats. So renaming the bundle = pointing it at a different game.

A bundle can also override AppSupport by placing
`<bundle>/CiderConfig/cider.json` next to `Contents/`. That folder
is a sibling of the signed/notarized `Contents/`, so it doesn't break
codesign — distributors can ship a fully self-contained `.app`.

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

## Configuration (`cider.json`)

```json
{
  "schemaVersion": 1,
  "displayName": "My Game",
  "exe": "MyGame/Game.exe",
  "args": ["/tui", "/log"],
  "source": {
    "mode": "path",
    "path": "/Users/me/Games/MyGame"
  },
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
  "icon": "icon.icns"
}
```

`source.mode` can be:
- `"path"` — folder or `.zip` on disk; **referenced by symlink**, never
  copied. Cider lazily extracts a `.zip` once into AppSupport.
- `"inBundle"` — a sibling of `Contents/` inside this `.app`
  (distributable mode).
- `"url"` — fetched on first launch into AppSupport's download cache;
  re-checked every launch via SHA-256 (or ETag/Last-Modified fallback)
  so Cider doubles as a patcher.

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
├── App/                    # SwiftUI / AppKit GUI + CLI router
│   ├── CiderApp.swift          # @main entry; dispatches CLI vs GUI
│   ├── BundleEnvironment.swift # bundle URL / name / writability
│   ├── AppShell.swift          # shared NSApplication + menu-bar setup
│   ├── CLI/                    # ArgumentParser subcommands
│   ├── DropZone/               # vanilla-bundle drag-drop window
│   ├── More/                   # SwiftUI configuration form
│   └── Splash/                 # borderless transparent splash + progress
├── Core/                   # Engine/template/graphics/prefix/wine/etc.
│   ├── EngineManager.swift     ├── TemplateManager.swift
│   ├── GraphicsDriver.swift    ├── PrefixInitializer.swift
│   ├── WineLauncher.swift      ├── ConsoleLineCounter.swift
│   ├── LaunchPipeline.swift    ├── SourceResolver.swift
│   ├── BundleTransmogrifier.swift
│   ├── IconConverter.swift     ├── Downloader.swift
│   ├── IntegrityChecker.swift  ├── ConfigStore.swift
│   ├── AppSupport.swift        ├── Logger.swift
│   └── Shell.swift
├── Models/                 # CiderConfig + CiderRuntimeStats schemas
├── Resources/Cider.entitlements    # hardened-runtime entitlements
├── scripts/
│   ├── build-app.sh        # SPM build → signed Cider.app
│   └── sign-and-notarize.sh # Developer ID + notarytool + stapler
├── Tests/CiderTests/       # XCTest suite (46+ tests)
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
