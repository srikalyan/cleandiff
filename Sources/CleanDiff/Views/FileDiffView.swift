import SwiftUI
import AppKit
import CleanDiffCore

// MARK: - Scroll Sync Coordinator

class ScrollSyncCoordinator: ObservableObject {
    weak var leftScrollView: NSScrollView?
    weak var rightScrollView: NSScrollView?
    private var isUpdating = false

    func register(scrollView: NSScrollView, side: DiffSide) {
        if side == .left {
            leftScrollView = scrollView
        } else {
            rightScrollView = scrollView
        }

        // Observe scroll changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard !isUpdating,
              let sourceScrollView = notification.object as? NSScrollView else { return }

        isUpdating = true

        let targetScrollView: NSScrollView?
        if sourceScrollView === leftScrollView {
            targetScrollView = rightScrollView
        } else if sourceScrollView === rightScrollView {
            targetScrollView = leftScrollView
        } else {
            targetScrollView = nil
        }

        if let target = targetScrollView {
            let sourceY = sourceScrollView.contentView.bounds.origin.y
            let targetPoint = NSPoint(x: 0, y: sourceY)
            target.contentView.scroll(to: targetPoint)
            target.reflectScrolledClipView(target.contentView)
        }

        isUpdating = false
    }
}

struct FileDiffView: View {
    @ObservedObject var viewModel: ComparisonViewModel
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("showLineNumbers") private var showLineNumbers = true

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            DiffToolbar(viewModel: viewModel)

            // Main diff area - aligned view
            AlignedDiffView(
                alignedLines: viewModel.alignedLines,
                leftTitle: viewModel.comparison.leftURL.lastPathComponent,
                rightTitle: viewModel.comparison.rightURL.lastPathComponent,
                fontSize: fontSize,
                showLineNumbers: showLineNumbers,
                selectedChunkIndex: viewModel.selectedChunkIndex,
                allChunks: viewModel.chunks,
                leftContent: $viewModel.leftContent,
                rightContent: $viewModel.rightContent,
                isLeftEditable: viewModel.isLeftWritable,
                isRightEditable: viewModel.isRightWritable,
                isLeftModified: viewModel.isLeftModified,
                isRightModified: viewModel.isRightModified,
                onContentChanged: { viewModel.recalculateDiff() }
            )

            // Status bar
            DiffStatusBar(viewModel: viewModel)
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

// MARK: - Aligned Diff View (Horizontally Synchronized)

struct AlignedDiffView: View {
    let alignedLines: [AlignedLine]
    let leftTitle: String
    let rightTitle: String
    let fontSize: Double
    let showLineNumbers: Bool
    let selectedChunkIndex: Int?
    let allChunks: [DiffChunk]
    @Binding var leftContent: String
    @Binding var rightContent: String
    let isLeftEditable: Bool
    let isRightEditable: Bool
    let onContentChanged: () -> Void

    private let lineHeight: CGFloat

    let isLeftModified: Bool
    let isRightModified: Bool

    init(alignedLines: [AlignedLine], leftTitle: String, rightTitle: String,
         fontSize: Double, showLineNumbers: Bool, selectedChunkIndex: Int?, allChunks: [DiffChunk],
         leftContent: Binding<String>, rightContent: Binding<String>,
         isLeftEditable: Bool, isRightEditable: Bool,
         isLeftModified: Bool, isRightModified: Bool,
         onContentChanged: @escaping () -> Void) {
        self.alignedLines = alignedLines
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.selectedChunkIndex = selectedChunkIndex
        self.allChunks = allChunks
        self._leftContent = leftContent
        self._rightContent = rightContent
        self.isLeftEditable = isLeftEditable
        self.isRightEditable = isRightEditable
        self.isLeftModified = isLeftModified
        self.isRightModified = isRightModified
        self.onContentChanged = onContentChanged
        self.lineHeight = fontSize * 1.4
    }

    // State for editable lines
    @State private var leftLines: [String] = []
    @State private var rightLines: [String] = []

    // Determine which side is editable (if both, prefer left)
    private var editableSide: DiffSide? {
        if isLeftEditable && isRightEditable {
            return .left  // Prefer left when both are editable
        } else if isLeftEditable {
            return .left
        } else if isRightEditable {
            return .right
        }
        return nil  // Neither editable
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left pane
                VStack(spacing: 0) {
                    // Header with edit indicator and copy/paste buttons
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)
                        Text(leftTitle + (isLeftModified ? " *" : ""))
                            .font(.headline)
                            .foregroundColor(isLeftModified ? .orange : .primary)
                        if !isLeftEditable {
                            Text("(read-only)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()

                        // Copy/Paste buttons
                        Button(action: copyLeftContent) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy left file content")

                        if isLeftEditable {
                            Button(action: pasteToLeft) {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help("Paste to left file")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))

                    // Content - fills remaining space
                    ScrollViewReader { proxy in
                        List {
                            ForEach(alignedLines) { line in
                                EditableLineRow(
                                    line: line,
                                    side: .left,
                                    fontSize: fontSize,
                                    lineHeight: lineHeight,
                                    showLineNumbers: showLineNumbers,
                                    isSelected: isLineInSelectedChunk(line, side: .left),
                                    minWidth: geometry.size.width / 2 - 10,
                                    isEditable: isLeftEditable,
                                    onEdit: { newText in
                                        updateLine(lineNumber: line.leftLineNumber, newText: newText, side: .left)
                                    },
                                    onInsertLineBelow: {
                                        insertLineBelow(lineNumber: line.leftLineNumber, side: .left)
                                    }
                                )
                                .id("left-\(line.id)")
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: selectedChunkIndex) { _, newIndex in
                            scrollToSelectedChunk(proxy: proxy, side: .left)
                        }
                        .onAppear {
                            initializeLines()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToSelectedChunk(proxy: proxy, side: .left)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Right pane
                VStack(spacing: 0) {
                    // Header with edit indicator and copy/paste buttons
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)
                        Text(rightTitle + (isRightModified ? " *" : ""))
                            .font(.headline)
                            .foregroundColor(isRightModified ? .orange : .primary)
                        if !isRightEditable {
                            Text("(read-only)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()

                        // Copy/Paste buttons
                        Button(action: copyRightContent) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy right file content")

                        if isRightEditable {
                            Button(action: pasteToRight) {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help("Paste to right file")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))

                    // Content - fills remaining space
                    ScrollViewReader { proxy in
                        List {
                            ForEach(alignedLines) { line in
                                EditableLineRow(
                                    line: line,
                                    side: .right,
                                    fontSize: fontSize,
                                    lineHeight: lineHeight,
                                    showLineNumbers: showLineNumbers,
                                    isSelected: isLineInSelectedChunk(line, side: .right),
                                    minWidth: geometry.size.width / 2 - 10,
                                    isEditable: isRightEditable,
                                    onEdit: { newText in
                                        updateLine(lineNumber: line.rightLineNumber, newText: newText, side: .right)
                                    },
                                    onInsertLineBelow: {
                                        insertLineBelow(lineNumber: line.rightLineNumber, side: .right)
                                    }
                                )
                                .id("right-\(line.id)")
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: selectedChunkIndex) { _, newIndex in
                            scrollToSelectedChunk(proxy: proxy, side: .right)
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToSelectedChunk(proxy: proxy, side: .right)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: leftContent) { _, _ in initializeLines() }
        .onChange(of: rightContent) { _, _ in initializeLines() }
    }

    private func initializeLines() {
        leftLines = leftContent.components(separatedBy: .newlines)
        rightLines = rightContent.components(separatedBy: .newlines)
    }

    @State private var debounceWorkItem: DispatchWorkItem?

    private func updateLine(lineNumber: Int?, newText: String, side: DiffSide) {
        guard let num = lineNumber else { return }
        let index = num - 1  // Convert 1-based to 0-based

        if side == .left {
            if index < leftLines.count {
                leftLines[index] = newText
                leftContent = leftLines.joined(separator: "\n")
            }
        } else {
            if index < rightLines.count {
                rightLines[index] = newText
                rightContent = rightLines.joined(separator: "\n")
            }
        }

        // Debounce diff recalculation
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onContentChanged] in
            onContentChanged()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func insertLineBelow(lineNumber: Int?, side: DiffSide) {
        guard let num = lineNumber else { return }
        let index = num  // Insert after this line (0-based index = num since num is 1-based)

        if side == .left {
            if index <= leftLines.count {
                leftLines.insert("", at: index)
                leftContent = leftLines.joined(separator: "\n")
            }
        } else {
            if index <= rightLines.count {
                rightLines.insert("", at: index)
                rightContent = rightLines.joined(separator: "\n")
            }
        }

        // Trigger immediate diff recalculation for new line
        debounceWorkItem?.cancel()
        onContentChanged()
    }

    private func scrollToSelectedChunk(proxy: ScrollViewProxy, side: DiffSide) {
        guard let chunkIndex = selectedChunkIndex,
              chunkIndex < allChunks.count else { return }

        let chunk = allChunks[chunkIndex]
        let targetLine = side == .left ? chunk.leftRange.lowerBound : chunk.rightRange.lowerBound

        // Find the aligned line index that corresponds to this target
        if let alignedIndex = findAlignedIndex(forLine: targetLine, side: side, operation: chunk.operation) {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("\(side == .left ? "left" : "right")-\(alignedIndex)", anchor: .top)
            }
        }
    }

    private func findAlignedIndex(forLine lineNumber: Int, side: DiffSide, operation: DiffOperation) -> Int? {
        for (index, aligned) in alignedLines.enumerated() {
            if aligned.operation == operation {
                let matchingLineNum = side == .left ? aligned.leftLineNumber : aligned.rightLineNumber
                if matchingLineNum == lineNumber + 1 {  // lineNumber is 0-based, leftLineNumber is 1-based
                    return index
                }
            }
        }
        return nil
    }

    private func isLineInSelectedChunk(_ line: AlignedLine, side: DiffSide) -> Bool {
        guard let chunkIndex = selectedChunkIndex,
              chunkIndex < allChunks.count else { return false }

        let chunk = allChunks[chunkIndex]
        guard line.operation == chunk.operation && line.operation != .equal else { return false }

        let lineNum = side == .left ? line.leftLineNumber : line.rightLineNumber
        guard let num = lineNum else { return false }

        let range = side == .left ? chunk.leftRange : chunk.rightRange
        return range.contains(num - 1)  // Convert 1-based to 0-based
    }

    // MARK: - Clipboard Operations

    private func copyToClipboard(_ content: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    private func pasteFromClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func copyLeftContent() {
        copyToClipboard(leftContent)
    }

    private func copyRightContent() {
        copyToClipboard(rightContent)
    }

    private func pasteToLeft() {
        if let text = pasteFromClipboard() {
            leftContent = text
            leftLines = text.components(separatedBy: .newlines)
            onContentChanged()
        }
    }

    private func pasteToRight() {
        if let text = pasteFromClipboard() {
            rightContent = text
            rightLines = text.components(separatedBy: .newlines)
            onContentChanged()
        }
    }
}

// MARK: - Editable Line Row

struct EditableLineRow: View {
    let line: AlignedLine
    let side: DiffSide
    let fontSize: Double
    let lineHeight: CGFloat
    let showLineNumbers: Bool
    let isSelected: Bool
    let minWidth: CGFloat
    let isEditable: Bool
    let onEdit: (String) -> Void
    let onInsertLineBelow: () -> Void  // Called when Enter is pressed

    @State private var editText: String = ""
    @State private var originalText: String = ""  // Track original to detect real changes
    @State private var isInitialized: Bool = false
    @FocusState private var isFocused: Bool

    private var text: String? {
        side == .left ? line.leftText : line.rightText
    }

    private var lineNumber: Int? {
        side == .left ? line.leftLineNumber : line.rightLineNumber
    }

    private var isPlaceholder: Bool {
        text == nil
    }

    private var backgroundColor: Color {
        let normalAlpha: Double = 0.2
        let selectedAlpha: Double = 0.45
        let alpha = isSelected ? selectedAlpha : normalAlpha

        if isPlaceholder {
            return Color.gray.opacity(0.1)
        }

        switch line.operation {
        case .equal:
            return .clear
        case .insert:
            return side == .right ? Color.green.opacity(alpha) : Color.gray.opacity(0.1)
        case .delete:
            return side == .left ? Color.red.opacity(alpha) : Color.gray.opacity(0.1)
        case .replace:
            return side == .left ? Color.orange.opacity(alpha) : Color.blue.opacity(alpha)
        case .conflict:
            return Color.purple.opacity(alpha)
        }
    }

    private var indicatorColor: Color {
        if isPlaceholder { return .clear }

        switch line.operation {
        case .equal: return .clear
        case .insert: return side == .right ? .green : .clear
        case .delete: return side == .left ? .red : .clear
        case .replace: return side == .left ? .orange : .blue
        case .conflict: return .purple
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showLineNumbers {
                // Indicator bar
                Rectangle()
                    .fill(indicatorColor)
                    .frame(width: 3)

                // Line number
                Text(lineNumber.map { String($0) } ?? "")
                    .font(.system(size: fontSize * 0.85, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 4)
            }

            // Content - editable or read-only based on permissions
            if isPlaceholder {
                // Placeholder - not editable, just empty space
                Rectangle()
                    .fill(Color.clear)
                    .frame(minWidth: minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity)
            } else if isEditable {
                // Editable TextField
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, design: .monospaced))
                    .focused($isFocused)
                    .frame(minWidth: minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .onAppear {
                        let t = text ?? ""
                        editText = t
                        originalText = t
                        // Mark as initialized after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isInitialized = true
                        }
                    }
                    .onChange(of: text) { _, newValue in
                        let t = newValue ?? ""
                        editText = t
                        originalText = t
                    }
                    .onSubmit {
                        // First save any pending edit
                        if isInitialized && editText != originalText {
                            onEdit(editText)
                            originalText = editText
                        }
                        // Then insert a new line below (Enter key behavior)
                        if isInitialized {
                            onInsertLineBelow()
                        }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused && isInitialized && editText != originalText {
                            onEdit(editText)
                            originalText = editText
                        }
                    }
            } else {
                // Read-only Text
                Text(text ?? "")
                    .font(.system(size: fontSize, design: .monospaced))
                    .frame(minWidth: minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
        }
        .frame(minWidth: minWidth, minHeight: lineHeight, maxHeight: lineHeight)
        .background(backgroundColor)
    }
}

struct DiffToolbar: View {
    @ObservedObject var viewModel: ComparisonViewModel

    var body: some View {
        HStack {
            // Navigation
            Button(action: { viewModel.previousChunk() }) {
                Image(systemName: "chevron.up")
            }
            .disabled(!viewModel.hasPreviousChunk)
            .help("Previous change")

            Button(action: { viewModel.nextChunk() }) {
                Image(systemName: "chevron.down")
            }
            .disabled(!viewModel.hasNextChunk)
            .help("Next change")

            Text("\(viewModel.currentChunkIndex + 1) of \(viewModel.chunks.count) changes")
                .foregroundColor(.secondary)
                .font(.caption)

            Spacer()

            // Actions
            Button(action: {
                Task {
                    try? await viewModel.saveAll()
                }
            }) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save all")

            Button(action: {
                Task {
                    await viewModel.loadAndDiff()
                }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

enum DiffSide {
    case left
    case right
}

// MARK: - Editable Diff Pane using NSTextView

struct EditableDiffPane: View {
    let title: String
    @Binding var content: String
    let diffResult: DiffResult
    let side: DiffSide
    let fontSize: Double
    let showLineNumbers: Bool
    let selectedChunkIndex: Int?
    let allChunks: [DiffChunk]
    let scrollSync: ScrollSyncCoordinator
    let onApplyChunk: (DiffChunk) -> Void
    let onContentChanged: () -> Void

    private var lineCount: Int {
        max(1, content.components(separatedBy: .newlines).count)
    }

    private var lineNumberWidth: CGFloat {
        let digitCount = String(lineCount).count
        return CGFloat(digitCount) * 8 + 12
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            // Main content area with line numbers
            HStack(spacing: 0) {
                // Line number gutter
                if showLineNumbers {
                    LineNumberGutter(
                        lineCount: lineCount,
                        fontSize: fontSize,
                        diffResult: diffResult,
                        side: side,
                        width: lineNumberWidth
                    )
                }

                // Editable text view with diff highlighting
                DiffTextView(
                    content: $content,
                    diffResult: diffResult,
                    side: side,
                    fontSize: fontSize,
                    showLineNumbers: showLineNumbers,
                    selectedChunkIndex: selectedChunkIndex,
                    allChunks: allChunks,
                    scrollSync: scrollSync,
                    onContentChanged: onContentChanged
                )
            }
        }
    }
}

// MARK: - Line Number Gutter (SwiftUI)

struct LineNumberGutter: View {
    let lineCount: Int
    let fontSize: Double
    let diffResult: DiffResult
    let side: DiffSide
    let width: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { lineNumber in
                    HStack(spacing: 0) {
                        // Diff indicator
                        Rectangle()
                            .fill(indicatorColor(for: lineNumber - 1))
                            .frame(width: 3)

                        Spacer()

                        Text("\(lineNumber)")
                            .font(.system(size: fontSize * 0.85, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)
                    }
                    .frame(height: fontSize * 1.2)
                }
            }
            .padding(.top, 4)
        }
        .frame(width: width)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func indicatorColor(for lineIndex: Int) -> Color {
        guard let chunk = chunkForLine(lineIndex) else { return .clear }

        switch chunk.operation {
        case .equal:
            return .clear
        case .insert:
            return side == .right ? .green : .clear
        case .delete:
            return side == .left ? .red : .clear
        case .replace:
            return side == .left ? .orange : .blue
        case .conflict:
            return .purple
        }
    }

    private func chunkForLine(_ lineIndex: Int) -> DiffChunk? {
        let chunks = diffResult.chunks
        let range = side == .left
            ? { (c: DiffChunk) in c.leftRange }
            : { (c: DiffChunk) in c.rightRange }

        return chunks.first { chunk in
            range(chunk).contains(lineIndex)
        }
    }
}

// MARK: - NSTextView wrapper for editable diff view

struct DiffTextView: NSViewRepresentable {
    @Binding var content: String
    let diffResult: DiffResult
    let side: DiffSide
    let fontSize: Double
    let showLineNumbers: Bool
    let selectedChunkIndex: Int?
    let allChunks: [DiffChunk]
    let scrollSync: ScrollSyncCoordinator
    let onContentChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Use NSTextView.scrollableTextView() for proper setup
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Register with scroll sync coordinator
        scrollSync.register(scrollView: scrollView, side: side)

        // Configure text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Configure for horizontal scrolling
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Set content
        textView.string = content
        textView.delegate = context.coordinator

        // Store reference for updates
        context.coordinator.textView = textView

        // Line numbers will be added in updateNSView after scroll view is ready

        // Apply initial highlighting
        DispatchQueue.main.async {
            self.applyDiffHighlighting(to: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update content if changed externally
        if textView.string != content {
            let selectedRange = textView.selectedRange()
            textView.string = content
            // Restore selection if valid
            if selectedRange.location + selectedRange.length <= textView.string.count {
                textView.setSelectedRange(selectedRange)
            }
        }

        // Apply font and text color to entire text
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.font = font
        textView.textColor = NSColor.textColor

        if let textStorage = textView.textStorage {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            if fullRange.length > 0 {
                textStorage.addAttribute(.font, value: font, range: fullRange)
                textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            }
        }

        // Update highlighting
        applyDiffHighlighting(to: textView)

        // Note: Line numbers handled by SwiftUI overlay instead of NSRulerView
        // NSRulerView was interfering with text visibility

        // Scroll to selected chunk if changed
        // allChunks is already filtered (non-equal only) from the view model
        if let chunkIndex = selectedChunkIndex,
           chunkIndex != context.coordinator.lastScrolledChunkIndex,
           chunkIndex < allChunks.count {
            let chunk = allChunks[chunkIndex]
            print("[DiffTextView] Scrolling to chunk \(chunkIndex): \(chunk.operation) at line \(side == .left ? chunk.leftRange.lowerBound : chunk.rightRange.lowerBound)")
            scrollToChunk(chunk, in: textView)
            context.coordinator.lastScrolledChunkIndex = chunkIndex
        }
    }

    private func scrollToChunk(_ chunk: DiffChunk, in textView: NSTextView) {
        let range = side == .left ? chunk.leftRange : chunk.rightRange
        guard !range.isEmpty else {
            print("[Scroll] Chunk range is empty, skipping")
            return
        }

        let lineIndex = range.lowerBound
        let string = textView.string as NSString

        // Find the character range for this line
        var currentLine = 0
        var charIndex = 0
        while currentLine < lineIndex && charIndex < string.length {
            let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = lineRange.upperBound
            currentLine += 1
        }

        guard charIndex < string.length,
              let layoutManager = textView.layoutManager,
              let scrollView = textView.enclosingScrollView else {
            print("[Scroll] Missing layout manager or scroll view")
            return
        }

        // Get the glyph range for the character index
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        // Adjust for text container inset
        lineRect.origin.y += textView.textContainerInset.height

        // Get visible area info
        let visibleRect = scrollView.contentView.bounds
        let documentHeight = textView.frame.height
        let viewportHeight = visibleRect.height

        print("[Scroll] Line \(lineIndex): lineRect.y=\(Int(lineRect.origin.y)), visibleRect=\(Int(visibleRect.origin.y))-\(Int(visibleRect.origin.y + visibleRect.height)), docHeight=\(Int(documentHeight)), viewportHeight=\(Int(viewportHeight))")

        // Check if document fits within viewport (no scrolling needed)
        if documentHeight <= viewportHeight {
            print("[Scroll] Document fits in viewport, no scroll needed")
            return
        }

        // Check if target line is already visible
        let lineTop = lineRect.origin.y
        let lineBottom = lineRect.origin.y + lineRect.height
        let visibleTop = visibleRect.origin.y
        let visibleBottom = visibleRect.origin.y + visibleRect.height

        if lineTop >= visibleTop && lineBottom <= visibleBottom {
            print("[Scroll] Line already visible, no scroll needed")
            return
        }

        // Determine scroll direction and position
        let targetY: CGFloat
        if lineTop < visibleTop {
            // Scrolling up - put line near top with some margin
            targetY = max(0, lineTop - 20)
            print("[Scroll] Scrolling UP to y=\(Int(targetY))")
        } else {
            // Scrolling down - put line near top with some margin
            targetY = max(0, lineTop - 20)
            print("[Scroll] Scrolling DOWN to y=\(Int(targetY))")
        }

        let targetPoint = NSPoint(x: 0, y: targetY)
        scrollView.contentView.scroll(to: targetPoint)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyDiffHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Reset background
        textStorage.removeAttribute(.backgroundColor, range: fullRange)

        let lines = side == .left ? diffResult.leftLines : diffResult.rightLines
        let string = textView.string as NSString

        // Get the selected chunk if any
        let selectedChunk: DiffChunk? = {
            guard let index = selectedChunkIndex, index < allChunks.count else { return nil }
            return allChunks[index]
        }()

        var lineStart = 0
        for (lineIndex, _) in lines.enumerated() {
            let lineEnd = string.lineRange(for: NSRange(location: lineStart, length: 0)).upperBound

            // Find chunk for this line
            if let chunk = chunkForLine(lineIndex) {
                let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let isSelected = selectedChunk != nil && isChunkSelected(chunk, selectedChunk: selectedChunk!)
                let color = backgroundColorForChunk(chunk, isSelected: isSelected)
                textStorage.addAttribute(.backgroundColor, value: color, range: lineRange)
            }

            lineStart = lineEnd
            if lineStart >= string.length { break }
        }
    }

    private func isChunkSelected(_ chunk: DiffChunk, selectedChunk: DiffChunk) -> Bool {
        // Compare by range since chunks don't have IDs
        return chunk.leftRange == selectedChunk.leftRange && chunk.rightRange == selectedChunk.rightRange
    }

    private func chunkForLine(_ lineIndex: Int) -> DiffChunk? {
        let chunks = diffResult.chunks
        let range = side == .left
            ? { (c: DiffChunk) in c.leftRange }
            : { (c: DiffChunk) in c.rightRange }

        return chunks.first { chunk in
            range(chunk).contains(lineIndex)
        }
    }

    private func backgroundColorForChunk(_ chunk: DiffChunk, isSelected: Bool) -> NSColor {
        // Use higher alpha for selected chunks
        let normalAlpha: CGFloat = 0.2
        let selectedAlpha: CGFloat = 0.45

        switch chunk.operation {
        case .equal:
            return .clear
        case .insert:
            let alpha = isSelected ? selectedAlpha : normalAlpha
            return side == .right ? NSColor.systemGreen.withAlphaComponent(alpha) : .clear
        case .delete:
            let alpha = isSelected ? selectedAlpha : normalAlpha
            return side == .left ? NSColor.systemRed.withAlphaComponent(alpha) : .clear
        case .replace:
            let alpha = isSelected ? selectedAlpha : normalAlpha
            return side == .left ? NSColor.systemOrange.withAlphaComponent(alpha) : NSColor.systemBlue.withAlphaComponent(alpha)
        case .conflict:
            let alpha = isSelected ? selectedAlpha : normalAlpha
            return NSColor.systemPurple.withAlphaComponent(alpha)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DiffTextView
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var lastScrolledChunkIndex: Int?
        private var debounceWorkItem: DispatchWorkItem?

        init(_ parent: DiffTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.content = textView.string

            // Debounce diff recalculation
            debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.parent.onContentChanged()
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)

            // Update ruler
            rulerView?.needsDisplay = true
        }
    }
}


// MARK: - Line Number Ruler View

class LineNumberRulerView: NSRulerView {
    var diffResult: DiffResult = .empty
    var side: DiffSide = .left

    weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 40

        // Observe text changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = self.textView,
              let layoutManager = textView.layoutManager,
              textView.textContainer != nil else { return }

        let visibleRect = scrollView?.contentView.bounds ?? rect
        let textViewInset = textView.textContainerInset

        // Background
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        // Draw line numbers
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        _ = textView.string as NSString  // Used for line counting
        var lineNumber = 1
        var glyphIndex = 0
        let numberOfGlyphs = layoutManager.numberOfGlyphs

        while glyphIndex < numberOfGlyphs {
            var lineRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)

            let lineY = lineRect.origin.y + textViewInset.height - visibleRect.origin.y

            if lineY + lineRect.height >= 0 && lineY <= rect.height {
                let lineStr = "\(lineNumber)"
                let strSize = lineStr.size(withAttributes: attrs)

                // Right-align the line number
                let x = ruleThickness - strSize.width - 4
                let y = lineY + (lineRect.height - strSize.height) / 2

                lineStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

                // Draw diff indicator
                if let chunk = chunkForLine(lineNumber - 1) {
                    let color = indicatorColorForChunk(chunk)
                    color.setFill()
                    let indicatorRect = NSRect(x: 0, y: lineY, width: 3, height: lineRect.height)
                    indicatorRect.fill()
                }
            }

            glyphIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // Update ruler thickness based on line count
        let digitCount = String(lineNumber).count
        let newThickness = CGFloat(digitCount * 8 + 12)
        if ruleThickness != newThickness {
            ruleThickness = newThickness
        }
    }

    private func chunkForLine(_ lineIndex: Int) -> DiffChunk? {
        let chunks = diffResult.chunks
        let range = side == .left
            ? { (c: DiffChunk) in c.leftRange }
            : { (c: DiffChunk) in c.rightRange }

        return chunks.first { chunk in
            range(chunk).contains(lineIndex)
        }
    }

    private func indicatorColorForChunk(_ chunk: DiffChunk) -> NSColor {
        switch chunk.operation {
        case .equal:
            return .clear
        case .insert:
            return side == .right ? .systemGreen : .clear
        case .delete:
            return side == .left ? .systemRed : .clear
        case .replace:
            return side == .left ? .systemOrange : .systemBlue
        case .conflict:
            return .systemPurple
        }
    }
}

// MARK: - Status Bar

struct DiffStatusBar: View {
    @ObservedObject var viewModel: ComparisonViewModel

    var body: some View {
        HStack {
            if viewModel.diffResult.hasChanges {
                Label("\(viewModel.diffResult.insertions) insertions", systemImage: "plus.circle")
                    .foregroundColor(.green)

                Label("\(viewModel.diffResult.deletions) deletions", systemImage: "minus.circle")
                    .foregroundColor(.red)

                Label("\(viewModel.diffResult.modifications) modifications", systemImage: "pencil.circle")
                    .foregroundColor(.orange)
            } else {
                Label("Files are identical", systemImage: "checkmark.circle")
                    .foregroundColor(.green)
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
    FileDiffView(viewModel: ComparisonViewModel(comparison: Comparison(
        leftURL: URL(fileURLWithPath: "/tmp/left.txt"),
        rightURL: URL(fileURLWithPath: "/tmp/right.txt"),
        baseURL: nil
    )))
}
