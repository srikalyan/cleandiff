import Foundation
import SwiftUI
import Combine
import CleanDiffCore

// MARK: - Aligned Line Model

struct AlignedLine: Identifiable {
    let index: Int              // Row index for stable ID
    let leftText: String?       // nil = placeholder
    let rightText: String?      // nil = placeholder
    let leftLineNumber: Int?    // nil for placeholders
    let rightLineNumber: Int?   // nil for placeholders
    let operation: DiffOperation

    // Stable ID that changes when operation changes (to trigger background refresh)
    var id: String {
        "\(index)-\(operation)"
    }
}

@MainActor
class ComparisonViewModel: ObservableObject {
    let comparison: Comparison

    @Published var diffResult: DiffResult = .empty
    @Published var alignedLines: [AlignedLine] = []
    @Published var threeWayResult: ThreeWayDiffResult?
    @Published var isLoading = false
    @Published var error: Error?
    @Published var selectedChunkIndex: Int?

    // Editor state
    @Published var leftContent: String = ""
    @Published var rightContent: String = ""
    @Published var baseContent: String = ""

    // Original content for tracking modifications
    private var originalLeftContent: String = ""
    private var originalRightContent: String = ""

    // File permissions
    @Published var isLeftWritable: Bool = false
    @Published var isRightWritable: Bool = false

    // Modification tracking
    var isLeftModified: Bool {
        leftContent != originalLeftContent
    }
    var isRightModified: Bool {
        rightContent != originalRightContent
    }

    // Navigation
    @Published var currentChunkIndex: Int = 0

    private let diffEngine = MyersDiff()

    init(comparison: Comparison) {
        self.comparison = comparison
        // Check file permissions
        checkFilePermissions()
    }

    private func checkFilePermissions() {
        let fm = FileManager.default
        isLeftWritable = fm.isWritableFile(atPath: comparison.leftURL.path)
        isRightWritable = fm.isWritableFile(atPath: comparison.rightURL.path)
        print("[ViewModel] File permissions - left: \(isLeftWritable ? "writable" : "read-only"), right: \(isRightWritable ? "writable" : "read-only")")
    }

    func loadAndDiff() async {
        isLoading = true
        error = nil

        print("[ViewModel] loadAndDiff called for \(comparison.leftURL.lastPathComponent)")

        do {
            // Load file contents
            leftContent = try await loadFile(comparison.leftURL)
            rightContent = try await loadFile(comparison.rightURL)
            // Store original content for modification tracking
            originalLeftContent = leftContent
            originalRightContent = rightContent
            print("[ViewModel] Loaded files - left: \(leftContent.count) chars, right: \(rightContent.count) chars")

            if let baseURL = comparison.baseURL {
                baseContent = try await loadFile(baseURL)
                // Three-way diff
                let baseLines = baseContent.components(separatedBy: .newlines)
                let leftLines = leftContent.components(separatedBy: .newlines)
                let rightLines = rightContent.components(separatedBy: .newlines)
                threeWayResult = diffEngine.diff3(base: baseLines, left: leftLines, right: rightLines)
            } else {
                // Two-way diff
                let leftLines = leftContent.components(separatedBy: .newlines)
                let rightLines = rightContent.components(separatedBy: .newlines)
                diffResult = diffEngine.diff(left: leftLines, right: rightLines)
                print("[ViewModel] Diff complete - leftLines: \(diffResult.leftLines.count), rightLines: \(diffResult.rightLines.count), chunks: \(diffResult.chunks.count)")
            }

            // Compute aligned lines for display
            computeAlignedLines()

            // Set initial chunk selection to trigger scroll to first diff
            currentChunkIndex = 0
            if !chunks.isEmpty {
                selectedChunkIndex = 0
            }
        } catch {
            self.error = error
            print("[ViewModel] Error loading files: \(error)")
        }

        isLoading = false
    }

    private func loadFile(_ url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Recalculate diff using current in-memory content (for live editing)
    func recalculateDiff() {
        print("[ViewModel] recalculateDiff called - using in-memory content")

        if comparison.baseURL != nil {
            // Three-way diff
            let baseLines = baseContent.components(separatedBy: .newlines)
            let leftLines = leftContent.components(separatedBy: .newlines)
            let rightLines = rightContent.components(separatedBy: .newlines)
            threeWayResult = diffEngine.diff3(base: baseLines, left: leftLines, right: rightLines)
        } else {
            // Two-way diff
            let leftLines = leftContent.components(separatedBy: .newlines)
            let rightLines = rightContent.components(separatedBy: .newlines)
            diffResult = diffEngine.diff(left: leftLines, right: rightLines)
            print("[ViewModel] Diff recalculated - chunks: \(diffResult.chunks.count), non-equal: \(chunks.count)")
        }

        // Recompute aligned lines for display
        computeAlignedLines()

        // Reset selection if chunks changed
        if chunks.isEmpty {
            selectedChunkIndex = nil
            currentChunkIndex = 0
        } else if currentChunkIndex >= chunks.count {
            currentChunkIndex = max(0, chunks.count - 1)
            selectedChunkIndex = currentChunkIndex
        }
    }

    // MARK: - Alignment Computation

    private func computeAlignedLines() {
        var aligned: [AlignedLine] = []
        let leftLines = diffResult.leftLines
        let rightLines = diffResult.rightLines

        for chunk in diffResult.chunks {
            switch chunk.operation {
            case .equal:
                // Equal lines - pair them up
                for i in 0..<chunk.leftRange.count {
                    let leftIdx = chunk.leftRange.lowerBound + i
                    let rightIdx = chunk.rightRange.lowerBound + i
                    aligned.append(AlignedLine(
                        index: aligned.count,
                        leftText: leftIdx < leftLines.count ? leftLines[leftIdx] : "",
                        rightText: rightIdx < rightLines.count ? rightLines[rightIdx] : "",
                        leftLineNumber: leftIdx + 1,
                        rightLineNumber: rightIdx + 1,
                        operation: .equal
                    ))
                }

            case .delete:
                // Lines only on left - right gets placeholders
                for i in chunk.leftRange {
                    aligned.append(AlignedLine(
                        index: aligned.count,
                        leftText: i < leftLines.count ? leftLines[i] : "",
                        rightText: nil,
                        leftLineNumber: i + 1,
                        rightLineNumber: nil,
                        operation: .delete
                    ))
                }

            case .insert:
                // Lines only on right - left gets placeholders
                for i in chunk.rightRange {
                    aligned.append(AlignedLine(
                        index: aligned.count,
                        leftText: nil,
                        rightText: i < rightLines.count ? rightLines[i] : "",
                        leftLineNumber: nil,
                        rightLineNumber: i + 1,
                        operation: .insert
                    ))
                }

            case .replace:
                // Both sides have lines - align by creating max(left, right) rows
                let leftCount = chunk.leftRange.count
                let rightCount = chunk.rightRange.count
                let maxCount = max(leftCount, rightCount)

                for i in 0..<maxCount {
                    let leftIdx = chunk.leftRange.lowerBound + i
                    let rightIdx = chunk.rightRange.lowerBound + i

                    let hasLeft = i < leftCount
                    let hasRight = i < rightCount

                    aligned.append(AlignedLine(
                        index: aligned.count,
                        leftText: hasLeft && leftIdx < leftLines.count ? leftLines[leftIdx] : nil,
                        rightText: hasRight && rightIdx < rightLines.count ? rightLines[rightIdx] : nil,
                        leftLineNumber: hasLeft ? leftIdx + 1 : nil,
                        rightLineNumber: hasRight ? rightIdx + 1 : nil,
                        operation: .replace
                    ))
                }

            case .conflict:
                // Similar to replace
                let leftCount = chunk.leftRange.count
                let rightCount = chunk.rightRange.count
                let maxCount = max(leftCount, rightCount)

                for i in 0..<maxCount {
                    let leftIdx = chunk.leftRange.lowerBound + i
                    let rightIdx = chunk.rightRange.lowerBound + i

                    let hasLeft = i < leftCount
                    let hasRight = i < rightCount

                    aligned.append(AlignedLine(
                        index: aligned.count,
                        leftText: hasLeft && leftIdx < leftLines.count ? leftLines[leftIdx] : nil,
                        rightText: hasRight && rightIdx < rightLines.count ? rightLines[rightIdx] : nil,
                        leftLineNumber: hasLeft ? leftIdx + 1 : nil,
                        rightLineNumber: hasRight ? rightIdx + 1 : nil,
                        operation: .conflict
                    ))
                }
            }
        }

        alignedLines = aligned
        print("[ViewModel] Computed \(aligned.count) aligned lines from \(leftLines.count) left + \(rightLines.count) right")

        // Debug first few lines
        for (i, line) in aligned.prefix(5).enumerated() {
            print("[Aligned \(i)] L:\(line.leftLineNumber ?? -1) '\(line.leftText ?? "<nil>")' | R:\(line.rightLineNumber ?? -1) '\(line.rightText ?? "<nil>")' op:\(line.operation)")
        }
    }

    // MARK: - Chunk Navigation

    var chunks: [DiffChunk] {
        diffResult.chunks.filter { $0.operation != .equal }
    }

    var hasNextChunk: Bool {
        currentChunkIndex < chunks.count - 1
    }

    var hasPreviousChunk: Bool {
        currentChunkIndex > 0
    }

    func nextChunk() {
        if hasNextChunk {
            currentChunkIndex += 1
            selectedChunkIndex = currentChunkIndex
        }
    }

    func previousChunk() {
        if hasPreviousChunk {
            currentChunkIndex -= 1
            selectedChunkIndex = currentChunkIndex
        }
    }

    // MARK: - Chunk Actions

    func applyChunkToRight(_ chunk: DiffChunk) {
        // Copy the left side to the right for this chunk
        var rightLines = rightContent.components(separatedBy: .newlines)
        let leftLines = leftContent.components(separatedBy: .newlines)

        let leftChunkLines = Array(leftLines[chunk.leftRange])

        // Replace the right range with left lines
        if chunk.rightRange.isEmpty {
            rightLines.insert(contentsOf: leftChunkLines, at: chunk.rightRange.lowerBound)
        } else {
            rightLines.replaceSubrange(chunk.rightRange, with: leftChunkLines)
        }

        rightContent = rightLines.joined(separator: "\n")

        // Re-diff
        Task {
            await loadAndDiff()
        }
    }

    func applyChunkToLeft(_ chunk: DiffChunk) {
        // Copy the right side to the left for this chunk
        var leftLines = leftContent.components(separatedBy: .newlines)
        let rightLines = rightContent.components(separatedBy: .newlines)

        let rightChunkLines = Array(rightLines[chunk.rightRange])

        // Replace the left range with right lines
        if chunk.leftRange.isEmpty {
            leftLines.insert(contentsOf: rightChunkLines, at: chunk.leftRange.lowerBound)
        } else {
            leftLines.replaceSubrange(chunk.leftRange, with: rightChunkLines)
        }

        leftContent = leftLines.joined(separator: "\n")

        // Re-diff
        Task {
            await loadAndDiff()
        }
    }

    // MARK: - Save

    func saveLeft() async throws {
        try leftContent.write(to: comparison.leftURL, atomically: true, encoding: .utf8)
    }

    func saveRight() async throws {
        try rightContent.write(to: comparison.rightURL, atomically: true, encoding: .utf8)
    }

    func saveAll() async throws {
        try await saveLeft()
        try await saveRight()
    }
}

// MARK: - Directory Comparison

extension ComparisonViewModel {
    struct DirectoryEntry: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let relativePath: String
        let leftURL: URL?
        let rightURL: URL?
        let status: FileStatus
        let isDirectory: Bool

        enum FileStatus: Hashable {
            case same
            case modified
            case leftOnly
            case rightOnly
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: DirectoryEntry, rhs: DirectoryEntry) -> Bool {
            lhs.id == rhs.id
        }
    }

    func compareDirectories() async -> [DirectoryEntry] {
        let leftContents = try? FileManager.default.contentsOfDirectory(
            at: comparison.leftURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let rightContents = try? FileManager.default.contentsOfDirectory(
            at: comparison.rightURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [DirectoryEntry] = []
        var seen = Set<String>()

        // Process left side
        for url in leftContents ?? [] {
            let name = url.lastPathComponent
            seen.insert(name)

            let rightURL = comparison.rightURL.appendingPathComponent(name)
            let rightExists = FileManager.default.fileExists(atPath: rightURL.path)

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            let status: DirectoryEntry.FileStatus
            if rightExists {
                if isDir {
                    status = .same  // Would need recursive comparison
                } else {
                    // Compare file contents
                    let leftData = try? Data(contentsOf: url)
                    let rightData = try? Data(contentsOf: rightURL)
                    status = leftData == rightData ? .same : .modified
                }
            } else {
                status = .leftOnly
            }

            entries.append(DirectoryEntry(
                name: name,
                relativePath: name,
                leftURL: url,
                rightURL: rightExists ? rightURL : nil,
                status: status,
                isDirectory: isDir
            ))
        }

        // Process right-only files
        for url in rightContents ?? [] {
            let name = url.lastPathComponent
            if !seen.contains(name) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                entries.append(DirectoryEntry(
                    name: name,
                    relativePath: name,
                    leftURL: nil,
                    rightURL: url,
                    status: .rightOnly,
                    isDirectory: isDir
                ))
            }
        }

        return entries.sorted { $0.name < $1.name }
    }
}
