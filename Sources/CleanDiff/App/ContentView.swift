import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            let _ = print("[ContentView] Rendering with \(appState.comparisons.count) comparisons")
            if appState.comparisons.isEmpty {
                WelcomeView()
            } else {
                TabView(selection: $appState.selectedComparisonId) {
                    ForEach(appState.comparisons) { comparison in
                        ComparisonTabView(comparison: comparison)
                            .tabItem {
                                Label(comparison.title, systemImage: comparison.icon)
                            }
                            .tag(comparison.id as UUID?)
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $appState.showNewComparisonSheet) {
            NewComparisonSheet()
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("CleanDiff")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("A fast, native macOS diff and merge tool")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                WelcomeButton(
                    title: "Compare Files",
                    subtitle: "Two-way file comparison",
                    icon: "doc.on.doc",
                    action: { appState.openFilePicker() }
                )

                WelcomeButton(
                    title: "Compare Directories",
                    subtitle: "Compare folder contents",
                    icon: "folder.badge.gearshape",
                    action: { appState.showNewComparisonSheet = true }
                )

                WelcomeButton(
                    title: "Three-Way Merge",
                    subtitle: "Resolve merge conflicts",
                    icon: "arrow.triangle.merge",
                    action: { appState.showNewComparisonSheet = true }
                )
            }
            .padding(.top, 16)
        }
        .padding(48)
    }
}

struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 280)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct ComparisonTabView: View {
    let comparison: Comparison
    @StateObject private var viewModel: ComparisonViewModel

    init(comparison: Comparison) {
        self.comparison = comparison
        self._viewModel = StateObject(wrappedValue: ComparisonViewModel(comparison: comparison))
    }

    var body: some View {
        Group {
            switch comparison.type {
            case .file:
                FileDiffView(viewModel: viewModel)
            case .directory:
                DirectoryDiffView(viewModel: viewModel)
            case .threeWay:
                ThreeWayMergeView(viewModel: viewModel)
            }
        }
        .task {
            await viewModel.loadAndDiff()
        }
    }
}

struct NewComparisonSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var comparisonType: ComparisonType = .file
    @State private var leftPath = ""
    @State private var rightPath = ""
    @State private var basePath = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("New Comparison")
                .font(.title2)
                .fontWeight(.semibold)

            Picker("Type", selection: $comparisonType) {
                Text("File").tag(ComparisonType.file)
                Text("Directory").tag(ComparisonType.directory)
                Text("Three-Way Merge").tag(ComparisonType.threeWay)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                PathInputField(label: "Left:", path: $leftPath)
                PathInputField(label: "Right:", path: $rightPath)

                if comparisonType == .threeWay {
                    PathInputField(label: "Base:", path: $basePath)
                }
            }
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Compare") {
                    let leftURL = URL(fileURLWithPath: leftPath)
                    let rightURL = URL(fileURLWithPath: rightPath)
                    let baseURL = comparisonType == .threeWay ? URL(fileURLWithPath: basePath) : nil
                    appState.addComparison(left: leftURL, right: rightURL, base: baseURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(leftPath.isEmpty || rightPath.isEmpty)
            }
            .padding()
        }
        .frame(width: 500)
        .padding()
    }
}

struct PathInputField: View {
    let label: String
    @Binding var path: String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 50, alignment: .trailing)

            TextField("Path", text: $path)
                .textFieldStyle(.roundedBorder)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    path = url.path
                }
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "textformat")
                }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("ignoreWhitespace") private var ignoreWhitespace = false
    @AppStorage("ignoreCase") private var ignoreCase = false

    var body: some View {
        Form {
            Toggle("Ignore whitespace differences", isOn: $ignoreWhitespace)
            Toggle("Ignore case differences", isOn: $ignoreCase)
        }
        .padding()
    }
}

struct EditorSettingsView: View {
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("showLineNumbers") private var showLineNumbers = true

    var body: some View {
        Form {
            Slider(value: $fontSize, in: 9...24, step: 1) {
                Text("Font Size: \(Int(fontSize))")
            }
            Toggle("Show line numbers", isOn: $showLineNumbers)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
