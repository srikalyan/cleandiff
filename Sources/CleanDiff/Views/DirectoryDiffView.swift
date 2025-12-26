import SwiftUI

struct DirectoryDiffView: View {
    @ObservedObject var viewModel: ComparisonViewModel
    @State private var entries: [ComparisonViewModel.DirectoryEntry] = []
    @State private var selectedEntry: ComparisonViewModel.DirectoryEntry?
    @State private var filter: EntryFilter = .all

    enum EntryFilter: String, CaseIterable {
        case all = "All"
        case modified = "Modified"
        case leftOnly = "Left Only"
        case rightOnly = "Right Only"
    }

    var filteredEntries: [ComparisonViewModel.DirectoryEntry] {
        switch filter {
        case .all:
            return entries
        case .modified:
            return entries.filter { $0.status == .modified }
        case .leftOnly:
            return entries.filter { $0.status == .leftOnly }
        case .rightOnly:
            return entries.filter { $0.status == .rightOnly }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            DirectoryToolbar(filter: $filter, entryCount: filteredEntries.count)

            HSplitView {
                // File list
                List(selection: $selectedEntry) {
                    ForEach(filteredEntries) { entry in
                        DirectoryEntryRow(entry: entry)
                            .tag(entry)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 300)

                // Detail view
                if let entry = selectedEntry {
                    DirectoryEntryDetail(entry: entry, viewModel: viewModel)
                } else {
                    VStack {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Select a file to compare")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Status bar
            DirectoryStatusBar(entries: entries)
        }
        .task {
            entries = await viewModel.compareDirectories()
        }
    }
}

struct DirectoryToolbar: View {
    @Binding var filter: DirectoryDiffView.EntryFilter
    let entryCount: Int

    var body: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(DirectoryDiffView.EntryFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer()

            Text("\(entryCount) items")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct DirectoryEntryRow: View {
    let entry: ComparisonViewModel.DirectoryEntry

    var body: some View {
        HStack {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(iconColor)

            Text(entry.name)
                .foregroundColor(textColor)

            Spacer()

            statusBadge
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch entry.status {
        case .same: return .secondary
        case .modified: return .orange
        case .leftOnly: return .red
        case .rightOnly: return .green
        }
    }

    private var textColor: Color {
        switch entry.status {
        case .same: return .primary
        case .modified: return .orange
        case .leftOnly: return .red
        case .rightOnly: return .green
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .same:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .modified:
            Image(systemName: "pencil.circle.fill")
                .foregroundColor(.orange)
        case .leftOnly:
            Image(systemName: "arrow.left.circle.fill")
                .foregroundColor(.red)
        case .rightOnly:
            Image(systemName: "arrow.right.circle.fill")
                .foregroundColor(.green)
        }
    }
}

struct DirectoryEntryDetail: View {
    let entry: ComparisonViewModel.DirectoryEntry
    @ObservedObject var viewModel: ComparisonViewModel
    @State private var detailViewModel: ComparisonViewModel?

    var body: some View {
        VStack {
            if entry.isDirectory {
                Text("Directory: \(entry.name)")
                    .font(.headline)
                Text("Recursive comparison not yet implemented")
                    .foregroundColor(.secondary)
            } else if let leftURL = entry.leftURL, let rightURL = entry.rightURL {
                if let detailVM = detailViewModel {
                    FileDiffView(viewModel: detailVM)
                } else {
                    ProgressView("Loading...")
                        .task {
                            let comparison = Comparison(
                                leftURL: leftURL,
                                rightURL: rightURL,
                                baseURL: nil
                            )
                            let vm = ComparisonViewModel(comparison: comparison)
                            await vm.loadAndDiff()
                            detailViewModel = vm
                        }
                }
            } else {
                // Single side only
                VStack(spacing: 16) {
                    Image(systemName: entry.leftURL != nil ? "arrow.left.circle" : "arrow.right.circle")
                        .font(.system(size: 48))
                        .foregroundColor(entry.leftURL != nil ? .red : .green)

                    Text(entry.leftURL != nil ? "File only exists in left" : "File only exists in right")
                        .font(.headline)

                    HStack(spacing: 20) {
                        if entry.leftURL != nil {
                            Button("Copy to Right") {
                                copyFile(from: entry.leftURL!, to: viewModel.comparison.rightURL.appendingPathComponent(entry.name))
                            }
                        }

                        if entry.rightURL != nil {
                            Button("Copy to Left") {
                                copyFile(from: entry.rightURL!, to: viewModel.comparison.leftURL.appendingPathComponent(entry.name))
                            }
                        }

                        Button("Delete") {
                            deleteFile(entry.leftURL ?? entry.rightURL!)
                        }
                        .foregroundColor(.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyFile(from source: URL, to destination: URL) {
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct DirectoryStatusBar: View {
    let entries: [ComparisonViewModel.DirectoryEntry]

    var body: some View {
        HStack {
            let same = entries.filter { $0.status == .same }.count
            let modified = entries.filter { $0.status == .modified }.count
            let leftOnly = entries.filter { $0.status == .leftOnly }.count
            let rightOnly = entries.filter { $0.status == .rightOnly }.count

            Label("\(same) same", systemImage: "checkmark.circle")
                .foregroundColor(.green)

            Label("\(modified) modified", systemImage: "pencil.circle")
                .foregroundColor(.orange)

            Label("\(leftOnly) left only", systemImage: "arrow.left.circle")
                .foregroundColor(.red)

            Label("\(rightOnly) right only", systemImage: "arrow.right.circle")
                .foregroundColor(.blue)

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

#Preview {
    DirectoryDiffView(viewModel: ComparisonViewModel(comparison: Comparison(
        leftURL: URL(fileURLWithPath: "/tmp/left"),
        rightURL: URL(fileURLWithPath: "/tmp/right"),
        baseURL: nil
    )))
}
