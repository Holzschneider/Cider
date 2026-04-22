# Cider

Bundle Windows apps into self-contained macOS `.app` wrappers using Wine.

Cider takes a Windows app (as a `.zip` or a directory), a prebuilt
[Sikarugir Wine engine](https://github.com/Sikarugir-App/Engines/releases), a
graphics driver (DXMT, D3DMetal, or DXVK), and an icon — and produces a
ready-to-run `.app` bundle:

```
cider bundle \
  --input ./MyGame.zip \
  --exe "MyGame/Game.exe" \
  --engine WS12WineCX24.0.7_7 \
  --graphics d3dmetal \
  --icon ./icon.png \
  --name "My Game" \
  --output "./My Game.app"
```

The produced `.app` contains a pre-initialised Wine prefix, a copy of the
engine, the Windows payload under `drive_c/Program Files/`, and a bash
launcher. Drag-to-install it to another Mac and it runs.

## Requirements

- macOS 12 (Monterey) or newer. Most Wine engines require 13+ in practice.
- Xcode 15+ (or Swift 5.9+ toolchain).
- Command line tools: `sips`, `iconutil`, `codesign`, `tar`, `unzip` — all
  shipped by macOS.

## Install

```sh
swift build -c release
cp .build/release/cider /usr/local/bin/cider
```

## Commands

```
cider bundle              # Create a .app bundle from a Windows app
cider engines list        # List cached Wine engines
cider engines pull <name> # Download an engine into the cache
cider inspect <bundle.app># Show metadata for a built bundle
cider cache path          # Print cache root (~/Library/Caches/Cider)
cider cache prune         # Clean up unreferenced engines
```

## Config file (TOML)

Pass `--with-config game.cider.toml` for reproducible builds:

```toml
[bundle]
input = "./MyGame.zip"
exe = "Game.exe"
name = "My Game"
bundle_id = "com.example.mygame"
output = "./My Game.app"

[engine]
name = "WS12WineCX24.0.7_7"
graphics = "dxmt"

[launch]
args = "--windowed --nosplash"

[icon]
path = "./icon.png"
```

## Graphics drivers

| Driver     | Notes |
| ---------- | ----- |
| `d3dmetal` | Apple's / CrossOver's Metal-based D3D11/12 translator. Best on Apple Silicon when shipped by the engine. |
| `dxmt`     | [3Shain/dxmt](https://github.com/3Shain/dxmt) — Metal-based D3D10/11 translator. Wide compatibility. |
| `dxvk`     | Vulkan via MoltenVK. Use on Intel or when D3DMetal/DXMT misbehave. |

Cider looks for the driver's DLLs inside the engine first; if the engine ships
D3DMetal or DXMT, those are copied into `drive_c/windows/system32/` and the
corresponding `WINEDLLOVERRIDES` are written into the launcher.

## Signing

By default Cider ad-hoc signs the produced bundle (`codesign --sign -`). This
works on the signing Mac but will show a Gatekeeper warning elsewhere. For
distribution, pass a Developer ID:

```sh
cider bundle ... --sign-identity "Developer ID Application: Your Name (TEAMID)"
```

## Bundle layout

```
My Game.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── MacOS/Launcher
    └── Resources/
        ├── AppIcon.icns
        ├── engine/                  # copy of the Wine engine
        ├── wineprefix/              # pre-initialised WINEPREFIX
        │   └── drive_c/
        │       ├── windows/system32/   # graphics driver DLLs
        │       └── Program Files/<name>/
        └── cider.json               # build metadata
```

## License & attribution

Cider itself is open source (see `LICENSE`). Wine engines bundled into your
`.app` carry the license of the engine producer — typically a mix of
LGPL (Wine itself) and the engine vendor's terms (CrossOver's CXPatent
restrictions for CrossOver-based engines). Cider does not redistribute
engines; they are fetched at bundle time from
[Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines/releases).
