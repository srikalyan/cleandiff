import Foundation

/// Represents a chunk of difference between two sequences
public enum DiffOperation: Equatable {
    case equal
    case insert
    case delete
    case replace
    case conflict  // For three-way merges
}

/// A single diff chunk representing a contiguous block of changes
public struct DiffChunk: Identifiable, Equatable {
    public let id = UUID()
    public let operation: DiffOperation
    public let leftRange: Range<Int>   // Line range in left file (start..<end)
    public let rightRange: Range<Int>  // Line range in right file

    public var leftLineCount: Int { leftRange.count }
    public var rightLineCount: Int { rightRange.count }

    public init(operation: DiffOperation, leftRange: Range<Int>, rightRange: Range<Int>) {
        self.operation = operation
        self.leftRange = leftRange
        self.rightRange = rightRange
    }

    /// For display purposes
    public var description: String {
        switch operation {
        case .equal:
            return "Equal: lines \(leftRange.lowerBound + 1)-\(leftRange.upperBound)"
        case .insert:
            return "Insert: \(rightLineCount) lines at \(rightRange.lowerBound + 1)"
        case .delete:
            return "Delete: \(leftLineCount) lines at \(leftRange.lowerBound + 1)"
        case .replace:
            return "Replace: \(leftLineCount) → \(rightLineCount) lines"
        case .conflict:
            return "Conflict: \(leftLineCount) vs \(rightLineCount) lines"
        }
    }
}

/// Result of a diff operation
public struct DiffResult {
    public let chunks: [DiffChunk]
    public let leftLines: [String]
    public let rightLines: [String]

    public init(chunks: [DiffChunk], leftLines: [String], rightLines: [String]) {
        self.chunks = chunks
        self.leftLines = leftLines
        self.rightLines = rightLines
    }

    public var hasChanges: Bool {
        chunks.contains { $0.operation != .equal }
    }

    public var insertions: Int {
        chunks.filter { $0.operation == .insert }.reduce(0) { $0 + $1.rightLineCount }
    }

    public var deletions: Int {
        chunks.filter { $0.operation == .delete }.reduce(0) { $0 + $1.leftLineCount }
    }

    public var modifications: Int {
        chunks.filter { $0.operation == .replace }.count
    }

    public static let empty = DiffResult(chunks: [], leftLines: [], rightLines: [])
}

/// Three-way diff result for merge operations
public struct ThreeWayDiffResult {
    public let chunks: [ThreeWayChunk]
    public let baseLines: [String]
    public let leftLines: [String]
    public let rightLines: [String]

    public init(chunks: [ThreeWayChunk], baseLines: [String], leftLines: [String], rightLines: [String]) {
        self.chunks = chunks
        self.baseLines = baseLines
        self.leftLines = leftLines
        self.rightLines = rightLines
    }

    public var hasConflicts: Bool {
        chunks.contains { $0.isConflict }
    }

    public var conflictCount: Int {
        chunks.filter { $0.isConflict }.count
    }
}

public struct ThreeWayChunk: Identifiable, Equatable {
    public let id = UUID()
    public let baseRange: Range<Int>
    public let leftRange: Range<Int>
    public let rightRange: Range<Int>
    public let status: ThreeWayStatus

    public init(baseRange: Range<Int>, leftRange: Range<Int>, rightRange: Range<Int>, status: ThreeWayStatus) {
        self.baseRange = baseRange
        self.leftRange = leftRange
        self.rightRange = rightRange
        self.status = status
    }

    public var isConflict: Bool {
        status == .conflict
    }
}

public enum ThreeWayStatus: Equatable {
    case unchanged          // All three match
    case leftChanged        // Only left differs from base
    case rightChanged       // Only right differs from base
    case bothChanged        // Both changed the same way (auto-merge)
    case conflict           // Conflicting changes
}
