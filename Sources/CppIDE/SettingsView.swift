import CppIDECore
import SwiftUI

/// CppIDE ▸ Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            ToolsSettingsTab()
                .tabItem { Label("Toolchain", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct EditorSettingsTab: View {
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = 4
    @AppStorage("formatOnSave") private var formatOnSave = false
    @AppStorage("inlayHints") private var inlayHints = true
    @AppStorage("inlineBlame") private var inlineBlame = true
    @AppStorage(SessionStore.reopenLastKey) private var reopenLast = true

    var body: some View {
        Form {
            LabeledContent("Font size") {
                HStack {
                    Slider(value: $fontSize, in: 9...24, step: 1).frame(width: 180)
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Tab width", selection: $tabWidth) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Toggle("Format with clang-format on save", isOn: $formatOnSave)
            Toggle("Show inlay hints (parameter names, inferred types)", isOn: $inlayHints)
            Toggle("Show Git blame for the current line", isOn: $inlineBlame)
            Toggle("Reopen the last project at launch", isOn: $reopenLast)
            Text("func main() {\n\tfmt.Println(\"preview\")\n}")
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct ToolsSettingsTab: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Form {
            Section {
                ToolPathRow(name: "clangd", hint: "xcode-select --install, or brew install llvm")
                ToolPathRow(name: "lldb-dap", hint: "ships with Xcode (xcrun -f lldb-dap) or brew install llvm")
                ToolPathRow(name: "cmake", hint: "brew install cmake")
                ToolPathRow(name: "ninja", hint: "optional: brew install ninja (faster CMake builds)")
                ToolPathRow(name: "clang++", hint: "xcode-select --install")
            } footer: {
                Text("Leave empty to search PATH, Homebrew (including keg-only LLVM) and xcrun.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Restart clangd") { Task { await workspace.restartLanguageServer() } }
                .disabled(workspace.rootURL == nil)
        }
    }
}

private struct ToolPathRow: View {
    let name: String
    let hint: String
    @AppStorage private var path: String

    init(name: String, hint: String) {
        self.name = name
        self.hint = hint
        _path = AppStorage(wrappedValue: "", ToolLocator.overrideKey(for: name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(name) {
                TextField("Auto-detect", text: $path).textFieldStyle(.roundedBorder)
            }
            Group {
                if let found = ToolLocator.find(name) {
                    Text("Using \(found.path)").foregroundStyle(.secondary)
                } else {
                    Text("Not found — \(hint)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .textSelection(.enabled)
        }
    }
}
