import CppIDECore
import SwiftUI

/// Toolbar menu: pick the configuration ⌘R and ⌥⌘R use.
struct RunConfigurationPicker: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            ForEach(workspace.runConfigurations) { config in
                Button {
                    workspace.selectedRunConfigurationID = config.id
                } label: {
                    if config.id == workspace.selectedRunConfiguration?.id {
                        Label(config.name, systemImage: "checkmark")
                    } else {
                        Text(config.name)
                    }
                }
            }
            Divider()
            Button("Edit Configurations…") { workspace.isEditingRunConfigurations = true }
        } label: {
            Label(workspace.selectedRunConfiguration?.name ?? "No target", systemImage: "terminal")
                .labelStyle(.titleAndIcon)
        }
        .help("Run configuration (⌘R runs it, ⌥⌘R debugs it)")
        .disabled(workspace.rootURL == nil)
    }
}

/// Sheet for adding/editing run configurations.
struct RunConfigurationsSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(workspace.runConfigurations) { Text($0.name).tag($0.id) }
                    }
                    HStack(spacing: 2) {
                        Button { add() } label: { Image(systemName: "plus") }
                        Button { remove() } label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(minWidth: 160, idealWidth: 180)

                Group {
                    if let index = workspace.runConfigurations.firstIndex(where: { $0.id == selection }) {
                        Form {
                            TextField("Name", text: $workspace.runConfigurations[index].name)
                            TargetField(target: $workspace.runConfigurations[index].target, choices: workspace.runTargets)
                            TextField("Arguments", text: $workspace.runConfigurations[index].arguments,
                                      prompt: Text("--port 8080 --name \"my app\""))
                                .font(.system(.body, design: .monospaced))
                            LabeledContent("Environment") {
                                TextEditor(text: $workspace.runConfigurations[index].environment)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                            }
                            Text("One KEY=value per line. Used by Run (⌘R) and Debug (⌥⌘R).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    } else {
                        Text("Select or add a configuration.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 470)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    if let selection { workspace.selectedRunConfigurationID = selection }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 720, height: 330)
        .onAppear {
            workspace.refreshRunTargets()
            selection = workspace.selectedRunConfiguration?.id
        }
    }

    private func add() {
        let config = RunConfiguration(name: "New Configuration", target: workspace.runTargets.first ?? "")
        workspace.runConfigurations.append(config)
        selection = config.id
    }

    private func remove() {
        workspace.runConfigurations.removeAll { $0.id == selection }
        selection = workspace.runConfigurations.first?.id
    }
}

/// Target name/path with a menu of what the project defines.
private struct TargetField: View {
    @Environment(Workspace.self) private var workspace
    @Binding var target: String
    let choices: [String]

    var body: some View {
        LabeledContent("Target") {
            HStack(spacing: 4) {
                TextField("", text: $target, prompt: Text(prompt))
                    .font(.system(.body, design: .monospaced))
                Menu {
                    ForEach(choices, id: \.self) { choice in Button(choice) { target = choice } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(choices.isEmpty)
            }
        }
        Text(help).font(.caption).foregroundStyle(.secondary)
    }

    private var prompt: String {
        workspace.buildSystem == .cmake ? "executable target" : "main.cpp or build/app"
    }

    private var help: String {
        switch workspace.buildSystem {
        case .cmake: "A CMake executable target: built with cmake --build, then run from the build tree."
        case .make: "A program make builds (path relative to the project), or a source file to compile on its own."
        case .plain: "A source file with main(): compiled with clang/clang++ into build/."
        }
    }
}
