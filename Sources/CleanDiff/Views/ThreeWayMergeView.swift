import SwiftUI
import CleanDiffCore

struct ThreeWayMergeView: View {
    @ObservedObject var viewModel: ComparisonViewModel
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("showLineNumbers") private var showLineNumbers = true

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            MergeToolbar(viewModel: viewModel)

            // Three panes
            HSplitView {
                // Left (ours)
                MergePane(
                    title: "Ours (Local)",
                    subtitle: viewModel.comparison.leftURL.lastPathComponent,
                    content: viewModel.leftContent,
                    lines: viewModel.threeWayResult?.leftLines ?? [],
                    fontSize: fontSize,
                    showLineNumbers: showLineNumbers,
                    side: .left
                )

                // Base (center)
                MergePane(
                    title: "Base (Common Ancestor)",
                    subtitle: viewModel.comparison.baseURL?.lastPathComponent ?? "base",
                    content: viewModel.baseContent,
                    lines: viewModel.threeWayResult?.baseLines ?? [],
                    fontSize: fontSize,
                    showLineNumbers: showLineNumbers,
                    side: .base
                )

                // Right (theirs)
                MergePane(
                    title: "Theirs (Remote)",
                    subtitle: viewModel.comparison.rightURL.lastPathComponent,
                    content: viewModel.rightContent,
                    lines: viewModel.threeWayResult?.rightLines ?? [],
                    fontSize: fontSize,
                    showLineNumbers: showLineNumbers,
                    side: .right
                )
            }

            // Conflict resolution panel
            if let result = viewModel.threeWayResult, result.hasConflicts {
                ConflictResolutionPanel(
                    conflictCount: result.conflictCount,
                    viewModel: viewModel
                )
            }

            // Status bar
            MergeStatusBar(viewModel: viewModel)
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
            }
        }
    }
}

struct MergeToolbar: View {
    @ObservedObject var viewModel: ComparisonViewModel

    var body: some View {
        HStack {
            // Navigation
            Button(action: { /* Previous conflict */ }) {
                Image(systemName: "chevron.up")
            }
            .help("Previous conflict")

            Button(action: { /* Next conflict */ }) {
                Image(systemName: "chevron.down")
            }
            .help("Next conflict")

            if let result = viewModel.threeWayResult {
                Text("\(result.conflictCount) conflicts")
                    .foregroundColor(result.hasConflicts ? .red : .green)
                    .font(.caption)
            }

            Spacer()

            // Actions
            Button("Use Left") {
                // Accept all left changes
            }
            .help("Accept all local changes")

            Button("Use Right") {
                // Accept all right changes
            }
            .help("Accept all remote changes")

            Divider()
                .frame(height: 20)

            Button(action: {
                Task {
                    try? await viewModel.saveAll()
                }
            }) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save merged result")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

enum MergeSide {
    case left
    case base
    case right
}

struct MergePane: View {
    let title: String
    let subtitle: String
    let content: String
    let lines: [String]
    let fontSize: Double
    let showLineNumbers: Bool
    let side: MergeSide

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(headerBackground)

            // Content
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        MergeLineView(
                            lineNumber: index + 1,
                            content: line,
                            fontSize: fontSize,
                            showLineNumbers: showLineNumbers,
                            side: side
                        )
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private var headerBackground: Color {
        switch side {
        case .left: return Color.blue.opacity(0.1)
        case .base: return Color.gray.opacity(0.1)
        case .right: return Color.green.opacity(0.1)
        }
    }
}

struct MergeLineView: View {
    let lineNumber: Int
    let content: String
    let fontSize: Double
    let showLineNumbers: Bool
    let side: MergeSide

    var body: some View {
        HStack(spacing: 0) {
            if showLineNumbers {
                Text("\(lineNumber)")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 8)
            }

            Text(content.isEmpty ? " " : content)
                .font(.system(size: fontSize, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .frame(height: fontSize + 6)
    }
}

struct ConflictResolutionPanel: View {
    let conflictCount: Int
    @ObservedObject var viewModel: ComparisonViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)

                Text("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s") require manual resolution")
                    .font(.headline)

                Spacer()

                Button("Mark Resolved") {
                    // Mark current conflict as resolved
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Use the arrows to accept changes from either side, or edit the merged result directly.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
        .border(Color.yellow.opacity(0.3), width: 1)
        .padding(.horizontal)
    }
}

struct MergeStatusBar: View {
    @ObservedObject var viewModel: ComparisonViewModel

    var body: some View {
        HStack {
            if let result = viewModel.threeWayResult {
                if result.hasConflicts {
                    Label("\(result.conflictCount) conflicts remaining", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                } else {
                    Label("All conflicts resolved", systemImage: "checkmark.circle")
                        .foregroundColor(.green)
                }
            }

            Spacer()

            if let error = viewModel.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

#Preview {
    ThreeWayMergeView(viewModel: ComparisonViewModel(comparison: Comparison(
        leftURL: URL(fileURLWithPath: "/tmp/left.txt"),
        rightURL: URL(fileURLWithPath: "/tmp/right.txt"),
        baseURL: URL(fileURLWithPath: "/tmp/base.txt")
    )))
}
