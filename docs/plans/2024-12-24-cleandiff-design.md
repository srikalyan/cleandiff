# CleanDiff Design Document

**Date:** 2024-12-24
**Status:** In Progress

## Overview

CleanDiff is a fast, native macOS diff and merge tool built with Swift and SwiftUI. It aims to fill the gap for a free, open-source diff tool on macOS with native look-and-feel and high performance.

## Goals

1. **Native macOS experience** - SwiftUI-based UI with proper macOS conventions
2. **High performance** - Instant diffs for typical source files
3. **Full feature set** - Two-way diff, three-way merge, directory comparison
4. **Git integration** - Works as `git difftool` and `git mergetool`
5. **Open source** - MIT licensed, community-driven

## Architecture

```
CleanDiff/
├── App/                    # Application entry point
│   ├── CleanDiffApp.swift  # @main app struct
│   └── ContentView.swift   # Main window
├── Models/
│   ├── Comparison.swift    # Comparison data model
│   ├── DiffChunk.swift     # Diff result types
│   └── ComparisonViewModel.swift
├── DiffEngine/
│   └── MyersDiff.swift     # Myers diff algorithm
├── GitIntegration/
│   └── GitService.swift    # Git operations
├── Views/
│   ├── FileDiffView.swift  # Two-way file diff
│   ├── DirectoryDiffView.swift
│   └── ThreeWayMergeView.swift
└── Utils/                  # Shared utilities
```

## Core Components

### 1. DiffEngine (MyersDiff)

Based on Eugene Myers' "An O(ND) Difference Algorithm":
- Time complexity: O((N+M)D) where D is the edit distance
- Space complexity: O((N+M)D)
- Produces minimal edit scripts

**Features:**
- Common prefix/suffix removal optimization
- Configurable: ignore whitespace, case, blank lines
- Three-way diff support for merge operations

### 2. Views

**FileDiffView:**
- Side-by-side panes with synchronized scrolling
- Line-by-line diff highlighting
- Inline chunk actions (apply left→right, right→left)
- Syntax highlighting (future: Tree-sitter integration)

**DirectoryDiffView:**
- Tree view of file hierarchies
- Status indicators: same, modified, left-only, right-only
- Drill-down into file diffs
- Bulk operations: copy, delete

**ThreeWayMergeView:**
- Three panes: ours, base, theirs
- Conflict detection and resolution
- Auto-merge for non-conflicting changes

### 3. Git Integration

```bash
# As difftool
git config --global diff.tool cleandiff
git config --global difftool.cleandiff.cmd 'cleandiff "$LOCAL" "$REMOTE"'

# As mergetool
git config --global merge.tool cleandiff
git config --global mergetool.cleandiff.cmd 'cleandiff "$LOCAL" "$BASE" "$REMOTE" -o "$MERGED"'
```

## Data Flow

```
User Action → AppState → ComparisonViewModel → DiffEngine
                                    ↓
                              DiffResult
                                    ↓
                            View Updates
```

## Performance Considerations

1. **Lazy loading** - Only process visible chunks
2. **Async operations** - File I/O and diff computation off main thread
3. **Incremental updates** - Re-diff only changed regions
4. **Memory efficiency** - Stream large files, don't load entirely

## Future Enhancements

### Phase 2
- Tree-sitter syntax highlighting
- Inline editing in diff view
- File watching (auto-refresh on change)
- Undo/redo for merge operations

### Phase 3
- Plugin system for version control (SVN, Mercurial)
- Custom diff algorithms (patience diff, histogram diff)
- Split/unified diff view modes
- Dark mode optimization

### Phase 4
- Homebrew formula
- Mac App Store release (optional)
- Localization

## Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | Swift | Native performance, macOS integration |
| UI | SwiftUI | Modern, declarative, Metal-backed |
| Diff Algorithm | Myers | Industry standard, minimal edits |
| Git | Subprocess | Compatibility, no library dependency |
| Distribution | Homebrew | Developer audience |

## References

- [Meld](https://meldmerge.org/) - Reference implementation
- [Myers Diff Paper](http://www.xmailserver.org/diff2.pdf)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
