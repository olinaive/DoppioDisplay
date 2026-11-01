# DoppioDisplay

macOS 26+ menu bar app (Apple Silicon): virtual displays, mirroring, picture in picture,
brightness (native / DDC / software), XDR Boost, presets and ICC profiles, Night Shift and
True Tone, profiles with automatic rules, shortcuts, `doppio://` URL scheme and CLI.
Formerly "VDisplay" (bundle `local.vdisplay`); settings are migrated once (`LegacyMigration`).

- Bundle ID `app.doppiodisplay`, URL scheme `doppio://` (old `vdisplay://` still accepted).
- Repo `github.com/olinaive/DoppioDisplay` (private), branch `main`.
- License: PolyForm Noncommercial 1.0.0 (`LICENSE.md`); third-party credits in
  `THIRD_PARTY_NOTICES.md` (MonitorControl, DeskPad, vdscreen, force-hidpi: MIT;
  KhaosT/CGVirtualDisplay: Apache-2.0). No GPL code may be copied in (BrightIntosh,
  opendisplay were only used as references).

## Commands

```sh
./scripts/build-app.sh                  # release build → build/DoppioDisplay.app (sets DEVELOPER_DIR to Xcode)
open build/DoppioDisplay.app            # quit the running one first: osascript -e 'tell application id "app.doppiodisplay" to quit'
swift test                              # unit tests (swift-testing), needs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/qa.sh address|thread|leaks      # scripted scenario under ASan+Main Thread Checker / TSan / leaks (NOMSL=1 ROUNDS=6 for footprint)
build/DoppioDisplay.app/Contents/MacOS/DoppioDisplay --selftest   # also: --brightness-probe --xdr-probe --color-probe --config-probe --mirror-probe
```

- Always build with the Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`);
  the Command Line Tools lack the SwiftUI macro plugin (`@State` fails).
- Builds are signed with the local self-signed identity "DoppioDisplay Local Signing"
  (`scripts/create-signing-identity.sh`) so macOS keeps Screen Recording across rebuilds.
  Ad-hoc signing resets permissions every build.
- Strict concurrency check: `swift build -Xswiftc -strict-concurrency=complete`. The only
  expected warnings are ColorSync C constants (`kColorSync…` declared `var` by Apple).
- Language mode is Swift 5 (`swiftLanguageMode(.v5)`); keep code clean under strict checking anyway.

## Releasing

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `scripts/build-app.sh`.
2. `./scripts/build-app.sh`, `codesign --verify --deep --strict build/DoppioDisplay.app`, `--selftest`.
3. `ditto -c -k --sequesterRsrc --keepParent build/DoppioDisplay.app .build/dist/DoppioDisplay-X.Y.Z.zip`
   (put archives in `.build/dist`, never `.build/release` — that is SwiftPM's build dir).
4. Commit, push, `gh release create vX.Y.Z <zip> --notes-file … --latest`. Notes in English and Russian,
   with SHA-256. Not notarized: users click "Open Anyway" once.
- Commit identity for this repo: `olinaive <33918829+olinaive@users.noreply.github.com>` (local git config;
  never the personal email). End commits with the `Co-Authored-By: Claude …` trailer.

## Layout

```
Sources/DoppioDisplay/
  App.swift               @main; flags (--selftest …); AppDelegate (URL handler, startup)
  MenuBarController.swift NSStatusItem + MenuPanelWindow (own menu bar panel, top-anchored)
  PanelWindow.swift       floating copy of the panel (doppio://panel)
  DisplayStore.swift      source of truth: configs, live virtual displays, mirrors, previews,
                          reconcile after sleep/reconfig, keep-awake, software mirrors, confirm/revert
  VirtualDisplay.swift    CGVirtualDisplay wrapper (private API)
  DisplayManager.swift    physical display list, hardware mirroring (CGConfigureDisplayMirrorOfDisplay)
  DisplayLayout.swift     arrangement, main display    DisplayModes.swift  resolutions / refresh / HiDPI pools
  SoftwareMirror.swift    physical → virtual "mirror" that keeps both resolutions (SCK capture + window)
  DisplayCapture.swift    ScreenCaptureKit stream into a CALayer (@MainActor; generation guard on start/stop)
  PreviewWindow.swift     PiP window: crop/rotate/flip/fps, full screen (green button, double-click)
  Brightness/             BrightnessStore, DDC (IOAVService), XDRBoost (EDR + gamma), ColorControls
  Profiles.swift, HotKeys.swift, URLCommands.swift, AppIcon.swift (icon + menu bar glyphs in code)
  Views/                  MenuPanel (cards), PanelComponents (shared row/menu styles), ArrangementMap,
                          Controls, SettingsView (AppKit-hosted window with sidebar)
Sources/CPrivateAPI/      CGVirtualDisplay declarations; shim.m: CoreBrightness, MonitorPanel (presets, rotation)
Resources/Doppio.icon     Icon Composer package (compiled by actool in build-app.sh)
design/tools/             icon and README hero generators (design/ itself is git-ignored)
```

## Things learned the hard way

- **Private APIs** are resolved at runtime (dlsym / NSClassFromString / respondsToSelector);
  controls hide when missing. `CGVirtualDisplaySettings.rotation` does nothing on macOS 27
  (virtual "90°" swaps width/height). MonitorPanel rotation works for physical displays.
- **Hardware mirroring forces one mode on both displays.** Physical → virtual therefore uses
  `SoftwareMirror`; virtual → physical stays hardware (HiDPI trick, custom built-in resolutions).
  Guard against feedback loops (a display shown on a virtual one that mirrors it back).
- **SwiftUI MenuBarExtra was replaced**: the system moved its window to other displays' menu bars
  on reconfiguration. The own panel follows the status item; do not reintroduce MenuBarExtra
  (an invisible `MenuBarExtra(isInserted: .constant(false))` only satisfies the Scene requirement).
- **NSMenu check marks are cached**: menus built from SwiftUI `Toggle`s get an `.id(...)` that
  changes with the state (see mirror menus).
- **Display reconfiguration (CGCompleteDisplayConfiguration) blocks the main thread** briefly;
  run animations first (Arrangement applies the position after the glide).
- Previews exclude the app's own windows from capture except software-mirror windows
  (`SoftwareMirror.windowNumbers`); rebuild previews when mirrors change.
- MenuBarExtra / NSStatusItem panels cannot be opened by clicking via System Events on macOS 27;
  use `doppio://menu` / `doppio://panel?expand=…` and `screencapture -l <windowID>` for screenshots
  (`design/tools/window-id.swift` lists window IDs).

## Working with the owner

- Speaks Russian; answers in Russian. Wants a mockup (HTML in `design/`, SF Symbols rendered via
  `design/tools/render-sf-symbols.swift`) and agreement **before** design changes; research and
  options before code when a direction is not decided.
- Do not click around or change their screen setup unprompted (rotation, mirroring, full screen);
  describe what to test instead. Opening our own windows for screenshots is fine.
- Privacy-conscious: no personal paths, emails or screen contents in commits/screenshots
  (blur status bars, avoid Apple wallpapers in published images).
- Confirm before releases and before making the repository public.

## Not yet verified on hardware

- DDC (brightness/contrast/volume/input) and every mirror involving an external monitor — no
  external monitor available so far.
- "HiDPI via virtual display" for non-Retina monitors.
- Full-screen PiP and built-in rotation/mode changes were not exercised automatically.
