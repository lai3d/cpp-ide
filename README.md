# CppIDE

[![CI](https://github.com/lai3d/cpp-ide/actions/workflows/ci.yml/badge.svg)](https://github.com/lai3d/cpp-ide/actions/workflows/ci.yml)

A native macOS IDE for C and C++, written in Swift (SwiftUI + AppKit).

> Early but usable: editing, navigation, refactoring, building, testing and debugging for CMake,
> Makefile and single-file C/C++ projects. Forked from [GoIDE](https://github.com/lai3d/golang-ide).

## Features

**Editor**
- Tabs with independent buffers, undo and scroll; unsaved-changes prompts
- C / C++ / Objective-C highlighting (raw strings, preprocessor, `#include <…>`) refined by clangd semantic tokens; inlay hints for parameter names and deduced types
- Line-number gutter with error/warning markers, Git change bars and code folding (⌥⌘← / ⌥⌘→)
- Occurrence highlights, current-line highlight, auto-indent, auto-closing brackets and quotes
- Toggle comment (⌘/), move / duplicate lines, indent / outdent
- Snippets: clangd call placeholders and built-ins with Tab stops, per language: C++ (`forr`, `class`, `ns`, `test`, …), C (`tstruct`, `malloc`, `utest`, `cmtest`, …) and both (`fori`, `guard`, `once`, …)
- Breadcrumbs (folder › file › namespace › class › function) above the editor
- clang-format via clangd: Format Document (⌥⇧F), optional format on save (honors `.clang-format`)

**Project**
- Sidebar file tree that follows changes on disk (FSEvents); new/rename/trash from the context menu (new headers start with `#pragma once`)
- Find in project (⇧⌘F): match case, whole word, regex — build directories are skipped
- Open Quickly (⌘P / ⇧⌘O): fuzzy file finder + workspace symbols; Outline sidebar for the current file
- Switch between header and source (⌃⌘↑)
- Git: status badges, branch in the title bar, inline blame, diff against HEAD, stage/commit
- Multiple windows, one project each (⇧⌘N); integrated terminal (⌃`)

**Language (clangd)**
- Live diagnostics and clang-tidy checks: underlines, gutter dots, Problems panel
- Completion with header insertion, hover docs, signature help while typing calls
- Jump to definition (⌘-click / ⌃⌘J), implementation (⌥⌘J), type definition (⌃⌥⌘J) and back (⌃⌘←); find references (⇧⌘R), call hierarchy (⌃⌥H)
- Rename symbol across files (⌃⌘E), quick fixes and refactorings (⌥↩)
- C projects (only `.c` sources): headers are C too, also without a `compile_commands.json` (clangd would otherwise read a lone `.h` as Objective-C++)

**Build, run, test & debug**
- **CMake**: configures `build/` on first build (Debug, Ninja when installed, `compile_commands.json` exported so clangd sees real flags), then `cmake --build`; Reconfigure and Clean in the Build menu
- **Make**: runs `make -jN`; **no build system**: compiles the active file with clang/clang++ (`-g -O0 -Wall -Wextra`) into `build/`, using the C / C++ standard from Settings ▸ Toolchain (C17 / C++20 by default) plus any flags in `compile_flags.txt`
- Run configurations (CMake executable target or source file, arguments, environment) for Run (⌘R) and Debug (⌥⌘R); compiler output `file.cpp:12:5` references are clickable
- Tests via CTest (⌘U all, ⌃⌥⌘U at cursor): Tests panel with per-test output; GoogleTest / Catch2 / Unity / CMocka tests get gutter ▶ / ✓ / ✗ (a Unity or CMocka function runs the ctest tests built from its file, and each function's result is read from the test output)
- Debugger (lldb-dap): click line numbers for breakpoints (with conditions), continue / step over (F6) / into (F7) / out (F8), call stack, expandable variables, watches, hover evaluation

See [ROADMAP.md](ROADMAP.md) for what's next.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)
- Xcode or the Command Line Tools (`xcode-select --install`) for clang, clangd and make;
  the debugger uses Xcode's `lldb-dap` (or Homebrew LLVM's)
- For CMake projects: `brew install cmake` (and optionally `ninja`)

CppIDE looks for tools on `PATH`, Homebrew (`/opt/homebrew/bin`, keg-only `opt/llvm/bin`) and
`xcrun`, so it works when launched from Finder too. Paths can be overridden in Settings ▸ Toolchain.

## Install

Download `CppIDE.zip` from [Releases](https://github.com/lai3d/cpp-ide/releases), unzip, and move
`CppIDE.app` to Applications. Builds are ad-hoc signed (not notarized), so the first time
right-click the app and choose **Open** (or run `xattr -dr com.apple.quarantine CppIDE.app`).

## Build & run

```sh
swift run CppIDE Examples/hello     # run in debug, opening the example project
swift test                         # unit tests + clangd / lldb-dap end-to-end tests
./scripts/bundle.sh                # build build/CppIDE.app + CppIDE.zip (release, ad-hoc signed)
open build/CppIDE.app
```

You can also open `Package.swift` in Xcode.

## Layout

| Path | What |
|---|---|
| `Sources/CppIDECore` | UI-independent core: JSON-RPC/LSP client, DAP client, C/C++ highlighter, CMake/CTest models, LSP position math, file tree |
| `Sources/CppIDE` | SwiftUI app: workspace state, editor view, sidebar, panels |
| `Tests/CppIDECoreTests` | swift-testing tests |
| `Examples/hello` | Small CMake project (library, executable, CTest tests) |
| `Examples/single` | A lone C file (no build system) |
| `scripts/` | `bundle.sh` (app bundle), `make-icon.swift` (regenerates `Resources/AppIcon.icns`) |
| `.github/workflows/` | CI (build, test, bundle) and tagged releases (`v*` → GitHub Release) |


## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.11.2 (MIT) — terminal emulation for the Terminal panel.
  Pinned before 1.12, whose Metal renderer needs Xcode's separately downloaded Metal toolchain.

## License

MIT — see [LICENSE](LICENSE).

## Releasing

Push a tag like `v0.2.0`; the Release workflow builds `CppIDE.zip` and attaches it to a GitHub
release. To ship a build that opens without Gatekeeper warnings you need, outside this repo:
an Apple Developer Program membership, a Developer ID Application certificate, and notarization
(`xcrun notarytool`) — then sign with that identity instead of `-` in `scripts/bundle.sh`.
