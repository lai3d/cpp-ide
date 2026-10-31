# CppIDE Roadmap

Status: ✅ done · 🚧 in progress · ⏸ waiting on a decision · ⬜ planned

Estimates are Claude Code session time.

## Phase 0 — Fork from GoIDE (2026-11-01)

The editor, LSP/DAP plumbing, Git, terminal, search, multi-window and session features come from
[GoIDE](https://github.com/lai3d/golang-ide); this phase swapped the language layer.

| # | Item | Notes | Est. |
|---|---|---|---|
| 0.1 | ✅ clangd | Language server with background index, clang-tidy, IWYU header insertion; `languageId` per extension; `compile_commands.json` changes forwarded | 0.5h |
| 0.2 | ✅ C/C++ highlighter | Regex lexer: comments, raw strings, char literals, preprocessor, `#include <…>`, numeric suffixes / `'` separators; clangd semantic tokens on top | 0.3h |
| 0.3 | ✅ Build systems | CMake (configure on first build, Debug, Ninja if present, File API for target artifacts), Make, single-file clang/clang++ | 0.8h |
| 0.4 | ✅ Run configurations | CMake executable targets / files with `main()`, arguments, environment | 0.3h |
| 0.5 | ✅ CTest | Streamed `ctest --output-on-failure` parsing into the Tests panel; GoogleTest / Catch2 gutter markers and run-at-cursor | 0.5h |
| 0.6 | ✅ lldb-dap debugger | DAP over stdio (Xcode's or Homebrew LLVM's lldb-dap); breakpoints, conditions, stepping, locals, watches | 0.5h |
| 0.7 | ✅ C++ niceties | Switch header/source (⌃⌘↑), C++ snippets, `#pragma once` / `#include` file templates, clang-format via clangd | 0.3h |
| 0.8 | ✅ Port tests, CI, icon, README | clangd / lldb-dap end-to-end tests; CI installs CMake + Ninja | 0.7h |

## Phase 1 — C/C++ depth

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ⬜ Build configurations | Debug / Release / RelWithDebInfo switcher (separate `build-<config>` dirs); `CMakePresets.json` support | 0.8h |
| 1.2 | ⬜ Problems from the build | Parse compiler `file:line:col: error:` lines into the Problems panel (not only clangd's) and color errors in Output | 0.4h |
| 1.3 | ⬜ Coverage | `-fprofile-instr-generate -fcoverage-mapping` + `llvm-cov export` → existing coverage tint | 1h |
| 1.4 | ⬜ Sanitizers | Toggle ASan / UBSan / TSan for a build configuration; make sanitizer reports clickable | 0.5h |
| 1.5 | ⬜ Attach to process | Pick a running process (DAP `attach` with `pid`) | 0.4h |
| 1.6 | ⬜ Disassembly & memory | DAP `disassemble` / `readMemory` views while paused; registers scope | 1.5h |
| 1.7 | ⬜ Inactive regions | Dim `#if 0` / disabled preprocessor branches (clangd inactiveRegions) | 0.3h |
| 1.8 | ⬜ CMake language support | Highlighting + completion for CMakeLists.txt (neocmakelsp if installed) | 0.6h |
| 1.9 | ⬜ Single-file flags | Per-folder `compile_flags.txt` editor (standard, include dirs, defines) used by both clangd and the compile step | 0.4h |
| 1.10 | ⬜ Package managers | vcpkg / Conan toolchain file detection when configuring | 0.6h |

## Phase 2 — Distribution

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ⬜ First release | Tag `v0.1.0`; verify the bundled app opens a window when launched with a folder (`NSTreatUnknownArgumentsAsOpen`) | 0.3h |
| 2.2 | ⬜ IDE Toolbox | Add CppIDE to the Toolbox catalog; shared recents already written | 0.2h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate, notarization credentials — only needed to ship a signed/notarized build to others.
