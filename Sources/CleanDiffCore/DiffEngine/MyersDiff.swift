import Foundation

/// Myers diff algorithm implementation
/// Based on "An O(ND) Difference Algorithm and Its Variations" by Eugene W. Myers
public struct MyersDiff {

    public struct Options {
        public var ignoreWhitespace: Bool = false
        public var ignoreCase: Bool = false
        public var ignoreBlankLines: Bool = false

        public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false, ignoreBlankLines: Bool = false) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreCase = ignoreCase
            self.ignoreBlankLines = ignoreBlankLines
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Compare two sequences of lines and return diff chunks
    public func diff(left: [String], right: [String]) -> DiffResult {
        let normalizedLeft = normalize(left)
        let normalizedRight = normalize(right)

        let editScript = computeEditScript(from: normalizedLeft, to: normalizedRight)
        let chunks = buildChunks(from: editScript, leftCount: left.count, rightCount: right.count)

        return DiffResult(chunks: chunks, leftLines: left, rightLines: right)
    }

    /// Compute the shortest edit script between two sequences
    private func computeEditScript(from a: [String], to b: [String]) -> [Edit] {
        let n = a.count
        let m = b.count

        // Handle edge cases
        if n == 0 && m == 0 {
            return []
        }
        if n == 0 {
            return (0..<m).map { Edit(type: .insert, leftIndex: 0, rightIndex: $0) }
        }
        if m == 0 {
            return (0..<n).map { Edit(type: .delete, leftIndex: $0, rightIndex: 0) }
        }

        // Quick check for identical arrays
        if a == b {
            return []
        }

        // V array: v[k] = x-coordinate of the furthest reaching path in diagonal k
        var v: [Int: Int] = [1: 0]

        // Trace array to reconstruct the path
        var trace: [[Int: Int]] = []

        // Main loop: find shortest edit script
        let maxD = n + m
        outerLoop: for d in 0...maxD {
            trace.append(v)
            var newV: [Int: Int] = [:]

            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                var y: Int

                // Decide whether to go down or right
                if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                    x = v[k + 1] ?? 0  // Move down (insert)
                } else {
                    x = (v[k - 1] ?? 0) + 1  // Move right (delete)
                }
                y = x - k

                // Follow diagonal (matches)
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }

                newV[k] = x

                if x >= n && y >= m {
                    trace.append(newV)
                    return backtrack(trace: trace, n: n, m: m)
                }
            }

            v = newV
        }

        // Fallback (shouldn't reach here)
        return []
    }

    /// Backtrack through the trace to build the edit script
    private func backtrack(trace: [[Int: Int]], n: Int, m: Int) -> [Edit] {
        var edits: [Edit] = []
        var x = n
        var y = m

        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let vPrev = trace[d - 1]
            let k = x - y

            var prevK: Int
            if k == -(d - 1) || (k != (d - 1) && (vPrev[k - 1] ?? 0) < (vPrev[k + 1] ?? 0)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = vPrev[prevK] ?? 0
            let prevY = prevX - prevK

            // Follow diagonal backwards (matches)
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
            }

            // Record the edit only if we actually moved from a valid position
            if x >= 0 && y >= 0 {
                if prevK == k + 1 && y > 0 {
                    // Insert (went down) - only if y > 0
                    y -= 1
                    edits.insert(Edit(type: .insert, leftIndex: x, rightIndex: y), at: 0)
                } else if prevK != k + 1 && x > 0 {
                    // Delete (went right) - only if x > 0
                    x -= 1
                    edits.insert(Edit(type: .delete, leftIndex: x, rightIndex: y), at: 0)
                }
            }
        }

        return edits
    }

    /// Build DiffChunks from the edit script
    private func buildChunks(from edits: [Edit], leftCount: Int, rightCount: Int) -> [DiffChunk] {
        // Handle the case where there are no edits (identical content)
        if edits.isEmpty {
            if leftCount > 0 && rightCount > 0 {
                return [DiffChunk(
                    operation: .equal,
                    leftRange: 0..<leftCount,
                    rightRange: 0..<rightCount
                )]
            }
            return []
        }

        var chunks: [DiffChunk] = []
        var leftPos = 0
        var rightPos = 0

        // Group edits by position
        var editIndex = 0
        while editIndex < edits.count {
            let edit = edits[editIndex]

            // Add equal chunk for any lines before this edit
            if edit.type == .delete && edit.leftIndex > leftPos {
                let equalCount = edit.leftIndex - leftPos
                chunks.append(DiffChunk(
                    operation: .equal,
                    leftRange: leftPos..<edit.leftIndex,
                    rightRange: rightPos..<(rightPos + equalCount)
                ))
                leftPos = edit.leftIndex
                rightPos += equalCount
            } else if edit.type == .insert && edit.rightIndex > rightPos {
                let equalCount = edit.rightIndex - rightPos
                chunks.append(DiffChunk(
                    operation: .equal,
                    leftRange: leftPos..<(leftPos + equalCount),
                    rightRange: rightPos..<edit.rightIndex
                ))
                leftPos += equalCount
                rightPos = edit.rightIndex
            }

            // Collect consecutive edits at this position
            var deleteCount = 0
            var insertCount = 0

            while editIndex < edits.count {
                let e = edits[editIndex]
                if e.type == .delete && e.leftIndex == leftPos + deleteCount {
                    deleteCount += 1
                    editIndex += 1
                } else if e.type == .insert && e.rightIndex == rightPos + insertCount {
                    insertCount += 1
                    editIndex += 1
                } else {
                    break
                }
            }

            // Create appropriate chunk
            if deleteCount > 0 && insertCount > 0 {
                chunks.append(DiffChunk(
                    operation: .replace,
                    leftRange: leftPos..<(leftPos + deleteCount),
                    rightRange: rightPos..<(rightPos + insertCount)
                ))
            } else if deleteCount > 0 {
                chunks.append(DiffChunk(
                    operation: .delete,
                    leftRange: leftPos..<(leftPos + deleteCount),
                    rightRange: rightPos..<rightPos
                ))
            } else if insertCount > 0 {
                chunks.append(DiffChunk(
                    operation: .insert,
                    leftRange: leftPos..<leftPos,
                    rightRange: rightPos..<(rightPos + insertCount)
                ))
            }

            leftPos += deleteCount
            rightPos += insertCount
        }

        // Add trailing equal chunk if needed
        if leftPos < leftCount && rightPos < rightCount {
            chunks.append(DiffChunk(
                operation: .equal,
                leftRange: leftPos..<leftCount,
                rightRange: rightPos..<rightCount
            ))
        }

        return mergeAdjacentChunks(chunks)
    }

    /// Merge adjacent chunks of the same type
    private func mergeAdjacentChunks(_ chunks: [DiffChunk]) -> [DiffChunk] {
        guard !chunks.isEmpty else { return [] }

        var merged: [DiffChunk] = []
        var current = chunks[0]

        for chunk in chunks.dropFirst() {
            if current.operation == chunk.operation &&
               current.leftRange.upperBound == chunk.leftRange.lowerBound &&
               current.rightRange.upperBound == chunk.rightRange.lowerBound {
                // Merge
                current = DiffChunk(
                    operation: current.operation,
                    leftRange: current.leftRange.lowerBound..<chunk.leftRange.upperBound,
                    rightRange: current.rightRange.lowerBound..<chunk.rightRange.upperBound
                )
            } else {
                merged.append(current)
                current = chunk
            }
        }
        merged.append(current)

        return merged
    }

    /// Normalize lines based on options
    private func normalize(_ lines: [String]) -> [String] {
        var result = lines

        if options.ignoreWhitespace {
            result = result.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        if options.ignoreCase {
            result = result.map { $0.lowercased() }
        }

        if options.ignoreBlankLines {
            result = result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        return result
    }
}

// MARK: - Internal Types

private struct Edit {
    enum EditType {
        case insert
        case delete
    }

    let type: EditType
    let leftIndex: Int
    let rightIndex: Int
}

// MARK: - Three-Way Diff

extension MyersDiff {

    /// Perform a three-way diff for merge operations
    public func diff3(base: [String], left: [String], right: [String]) -> ThreeWayDiffResult {
        let baseDiffLeft = diff(left: base, right: left)
        let baseDiffRight = diff(left: base, right: right)

        let chunks = merge3Way(
            baseLeft: baseDiffLeft.chunks,
            baseRight: baseDiffRight.chunks,
            baseCount: base.count,
            leftCount: left.count,
            rightCount: right.count
        )

        return ThreeWayDiffResult(
            chunks: chunks,
            baseLines: base,
            leftLines: left,
            rightLines: right
        )
    }

    private func merge3Way(
        baseLeft: [DiffChunk],
        baseRight: [DiffChunk],
        baseCount: Int,
        leftCount: Int,
        rightCount: Int
    ) -> [ThreeWayChunk] {
        // Simplified three-way merge logic
        // A full implementation would be more complex
        var chunks: [ThreeWayChunk] = []

        var basePos = 0
        var leftPos = 0
        var rightPos = 0

        // Find regions where changes overlap
        while basePos < baseCount || leftPos < leftCount || rightPos < rightCount {
            let leftChunk = baseLeft.first { $0.leftRange.contains(basePos) || $0.leftRange.lowerBound == basePos }
            let rightChunk = baseRight.first { $0.leftRange.contains(basePos) || $0.leftRange.lowerBound == basePos }

            let leftChanged = leftChunk?.operation != .equal && leftChunk?.operation != nil
            let rightChanged = rightChunk?.operation != .equal && rightChunk?.operation != nil

            let status: ThreeWayStatus
            if !leftChanged && !rightChanged {
                status = .unchanged
            } else if leftChanged && !rightChanged {
                status = .leftChanged
            } else if !leftChanged && rightChanged {
                status = .rightChanged
            } else {
                // Both changed - check if they're the same change
                status = .conflict
            }

            let baseEnd = min(basePos + 1, baseCount)
            let leftEnd = min(leftPos + 1, leftCount)
            let rightEnd = min(rightPos + 1, rightCount)

            chunks.append(ThreeWayChunk(
                baseRange: basePos..<baseEnd,
                leftRange: leftPos..<leftEnd,
                rightRange: rightPos..<rightEnd,
                status: status
            ))

            basePos = baseEnd
            leftPos = leftEnd
            rightPos = rightEnd
        }

        return chunks
    }
}
