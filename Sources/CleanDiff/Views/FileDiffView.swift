import SwiftUI
import AppKit
import CleanDiffCore
import os
import Combine

private let logger = Logger(subsystem: "com.cleandiff", category: "editing")

// MARK: - Undo/Redo Manager for NSTextView

/// Manages undo/redo state by monitoring the first responder's undo manager.
/// This bridges NSTextView's built-in undo support with SwiftUI toolbar buttons.
@MainActor
class UndoRedoManager: ObservableObject {
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    private var timer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        // Poll the first responder's undo manager state
        // We use a timer because the undo manager state changes frequently
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateUndoState()
            }
        }

        // Also observe undo manager notifications for immediate updates
        let undoNotification = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateUndoState()
            }
        }
        notificationObservers.append(undoNotification)

        let redoNotification = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidRedoChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateUndoState()
            }
        }
        notificationObservers.append(redoNotification)

        let checkpointNotification = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateUndoState()
            }
        }
        notificationObservers.append(checkpointNotification)
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func updateUndoState() {
        guard let undoManager = currentUndoManager() else {
            canUndo = false
            canRedo = false
            return
        }
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    /// Get the undo manager from the current first responder (usually an NSTextView)
    private func currentUndoManager() -> UndoManager? {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return nil
        }

        // If the first responder is an NSTextView, use its undo manager
        if let textView = firstResponder as? NSTextView {
            return textView.undoManager
        }

        // If it's a field editor (used by NSTextField), get its undo manager
        if let fieldEditor = firstResponder as? NSText {
            return fieldEditor.undoManager
        }

        return nil
    }

    /// Perform undo via the responder chain
    func undo() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        // Update state after a brief delay to let the undo complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateUndoState()
        }
    }

    /// Perform redo via the responder chain
    func redo() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        // Update state after a brief delay to let the redo complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateUndoState()
        }
    }
}

// MARK: - Custom TextField (No Word Wrap - uses NSTextField)

struct EditableTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let wordWrap: Bool  // Not used for NSTextField, kept for API compatibility
    let onEnterPressed: (Int) -> Void  // Pass cursor position
    let onTextChanged: (String) -> Void
    var onDeleteEmptyLine: (() -> Void)?
    var shouldFocus: Bool = false
    var onFocusHandled: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.font = font
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.alignment = .left
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Critical: Update coordinator's parent reference
        context.coordinator.parent = self
        
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        
        // Handle focus request
        if shouldFocus {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                // Position cursor at start
                if let fieldEditor = nsView.window?.fieldEditor(false, for: nsView) as? NSTextView {
                    fieldEditor.setSelectedRange(NSRange(location: 0, length: 0))
                }
                self.onFocusHandled?()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditableTextField

        init(_ parent: EditableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
            parent.onTextChanged(textField.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Get cursor position and pass to callback
                let cursorPos = textView.selectedRange().location
                parent.onEnterPressed(cursorPos)
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if parent.text.isEmpty {
                    parent.onDeleteEmptyLine?()
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - Text Height Calculator (Font-agnostic)

/// Calculates the height needed for text at a given width with a given font.
/// Uses TextKit for accurate measurement - works with any font/size.
enum TextHeightCalculator {
    static func height(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty, width > 0 else {
            return font.pointSize + 8  // Minimum height for empty text
        }

        let textStorage = NSTextStorage(string: text)
        textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textStorage.length))

        let textContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return max(usedRect.height + 4, font.pointSize + 8)
    }
}

// MARK: - Custom TextView (Word Wrap - uses NSTextView)

struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textWidth: CGFloat
    let onEnterPressed: (Int) -> Void
    let onTextChanged: (String) -> Void
    var onDeleteEmptyLine: (() -> Void)?
    var onSplitLine: ((String, String) -> Void)?
    var shouldFocus: Bool = false
    var onFocusHandled: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        // Create text view
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true

        // Critical: Word wrap configuration
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        // Set min/max size to enforce width
        textView.minSize = NSSize(width: textWidth, height: 0)
        textView.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)

        textView.string = text

        // Wrap in scroll view (required for proper NSTextView behavior)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // CRITICAL: Update coordinator's parent reference so callbacks use current closures
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
        }
        textView.font = font

        // Update width constraints
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.minSize = NSSize(width: textWidth, height: 0)
        textView.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)

        // Handle focus request
        if shouldFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                // Move cursor to start of text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                onFocusHandled?()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView
        weak var textView: NSTextView?

        init(_ parent: EditableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string

            // Check for newline (Enter pressed)
            if newText.contains("\n") {
                if let newlineIndex = newText.firstIndex(of: "\n") {
                    let beforeNewline = String(newText[..<newlineIndex])
                    let afterIndex = newText.index(after: newlineIndex)
                    let afterNewline = afterIndex < newText.endIndex ? String(newText[afterIndex...]) : ""

                    logger.info("Enter detected - before: '\(beforeNewline.prefix(30), privacy: .public)' after: '\(afterNewline.prefix(30), privacy: .public)'")

                    textView.string = beforeNewline
                    parent.text = beforeNewline

                    if let splitHandler = parent.onSplitLine {
                        splitHandler(beforeNewline, afterNewline)
                    } else {
                        parent.onTextChanged(beforeNewline)
                        parent.onEnterPressed(beforeNewline.count)
                    }
                }
            } else {
                parent.text = newText
                parent.onTextChanged(newText)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if parent.text.isEmpty {
                    parent.onDeleteEmptyLine?()
                    return true
                }
            }
            return false
        }
    }
}

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
    @AppStorage("wordWrap") private var wordWrap = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            DiffToolbar(viewModel: viewModel, wordWrap: $wordWrap)

            // Main diff area - aligned view
            AlignedDiffView(
                alignedLines: viewModel.alignedLines,
                leftTitle: viewModel.comparison.leftURL.lastPathComponent,
                rightTitle: viewModel.comparison.rightURL.lastPathComponent,
                fontSize: fontSize,
                showLineNumbers: showLineNumbers,
                wordWrap: wordWrap,
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
    let wordWrap: Bool
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
         fontSize: Double, showLineNumbers: Bool, wordWrap: Bool,
         selectedChunkIndex: Int?, allChunks: [DiffChunk],
         leftContent: Binding<String>, rightContent: Binding<String>,
         isLeftEditable: Bool, isRightEditable: Bool,
         isLeftModified: Bool, isRightModified: Bool,
         onContentChanged: @escaping () -> Void) {
        self.alignedLines = alignedLines
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.wordWrap = wordWrap
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

    // Focus management - which line should receive focus (side, lineNumber)
    @State private var focusedLine: (side: DiffSide, lineNumber: Int)? = nil

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

    // Calculate maximum line length for horizontal scrolling
    private var maxLineLength: Int {
        var maxLen = 0
        for line in alignedLines {
            if let left = line.leftText {
                maxLen = max(maxLen, left.count)
            }
            if let right = line.rightText {
                maxLen = max(maxLen, right.count)
            }
        }
        return maxLen
    }

    // Calculate content width based on longest line (when word wrap is off)
    private func contentWidth(paneWidth: CGFloat) -> CGFloat {
        if wordWrap {
            return paneWidth
        }
        // Estimate character width for monospaced font (roughly 0.6 * fontSize)
        let charWidth = fontSize * 0.6
        let lineNumberWidth: CGFloat = showLineNumbers ? 47 : 0
        let estimatedWidth = CGFloat(maxLineLength) * charWidth + lineNumberWidth + 20
        return max(paneWidth, estimatedWidth)
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

                    // Content - fills remaining space with horizontal scroll support
                    ScrollViewReader { proxy in
                        let paneWidth = geometry.size.width / 2 - 10
                        let scrollAxes: Axis.Set = wordWrap ? .vertical : [.horizontal, .vertical]
                        ScrollView(scrollAxes, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(alignedLines) { line in
                                    EditableLineRow(
                                        line: line,
                                        side: .left,
                                        fontSize: fontSize,
                                        lineHeight: lineHeight,
                                        showLineNumbers: showLineNumbers,
                                        wordWrap: wordWrap,
                                        isSelected: isLineInSelectedChunk(line, side: .left),
                                        minWidth: contentWidth(paneWidth: paneWidth),
                                        paneWidth: paneWidth,
                                        isEditable: isLeftEditable,
                                        onEdit: { newText in
                                            updateLine(lineNumber: line.leftLineNumber, newText: newText, side: .left)
                                        },
                                        onInsertLineBelow: { textForNewLine in
                                            insertLineBelow(lineNumber: line.leftLineNumber, side: .left, withText: textForNewLine)
                                        },
                                        onDeleteLine: {
                                            deleteLine(lineNumber: line.leftLineNumber, side: .left)
                                        },
                                        shouldFocus: focusedLine?.side == .left && focusedLine?.lineNumber == line.leftLineNumber,
                                        onFocusHandled: { focusedLine = nil }
                                    )
                                    .id("left-\(line.id)")
                                }
                            }
                            .frame(minWidth: wordWrap ? nil : contentWidth(paneWidth: paneWidth), alignment: .topLeading)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: selectedChunkIndex) { _, newIndex in
                            if newIndex != nil {
                                scrollToSelectedChunk(proxy: proxy, side: .left)
                            }
                        }
                        .onAppear {
                            initializeLines()
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

                    // Content - fills remaining space with horizontal scroll support
                    ScrollViewReader { proxy in
                        let paneWidth = geometry.size.width / 2 - 10
                        let scrollAxes: Axis.Set = wordWrap ? .vertical : [.horizontal, .vertical]

                        ScrollView(scrollAxes, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(alignedLines) { line in
                                    EditableLineRow(
                                        line: line,
                                        side: .right,
                                        fontSize: fontSize,
                                        lineHeight: lineHeight,
                                        showLineNumbers: showLineNumbers,
                                        wordWrap: wordWrap,
                                        isSelected: isLineInSelectedChunk(line, side: .right),
                                        minWidth: contentWidth(paneWidth: paneWidth),
                                        paneWidth: paneWidth,
                                        isEditable: isRightEditable,
                                        onEdit: { newText in
                                            updateLine(lineNumber: line.rightLineNumber, newText: newText, side: .right)
                                        },
                                        onInsertLineBelow: { textForNewLine in
                                            insertLineBelow(lineNumber: line.rightLineNumber, side: .right, withText: textForNewLine)
                                        },
                                        onDeleteLine: {
                                            deleteLine(lineNumber: line.rightLineNumber, side: .right)
                                        },
                                        shouldFocus: focusedLine?.side == .right && focusedLine?.lineNumber == line.rightLineNumber,
                                        onFocusHandled: { focusedLine = nil }
                                    )
                                    .id("right-\(line.id)")
                                }
                            }
                            .frame(minWidth: wordWrap ? nil : contentWidth(paneWidth: paneWidth), alignment: .topLeading)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: selectedChunkIndex) { _, newIndex in
                            if newIndex != nil {
                                scrollToSelectedChunk(proxy: proxy, side: .right)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: leftContent) { _, _ in
            // Only reinitialize if we're not in the middle of an internal update
            if !isInternalUpdate {
                initializeLines()
            }
        }
        .onChange(of: rightContent) { _, _ in
            if !isInternalUpdate {
                initializeLines()
            }
        }
    }

    private func initializeLines() {
        leftLines = leftContent.components(separatedBy: .newlines)
        rightLines = rightContent.components(separatedBy: .newlines)
    }

    @State private var debounceWorkItem: DispatchWorkItem?
    @State private var isInternalUpdate = false

    private func updateLine(lineNumber: Int?, newText: String, side: DiffSide) {
        guard let num = lineNumber else { return }
        let index = num - 1  // Convert 1-based to 0-based

        isInternalUpdate = true

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

        // Reset flag after a brief delay to allow onChange to fire first
        DispatchQueue.main.async {
            isInternalUpdate = false
        }

        // Debounce diff recalculation
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onContentChanged] in
            onContentChanged()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func insertLineBelow(lineNumber: Int?, side: DiffSide, withText: String = "") {
        guard let num = lineNumber else {
            logger.error("insertLineBelow: lineNumber is nil!")
            return
        }
        let index = num  // Insert after this line (1-based lineNumber means insert at that index)
        let arrayCount = side == .left ? leftLines.count : rightLines.count

        logger.info("insertLineBelow: lineNumber=\(num), side=\(String(describing: side), privacy: .public), arrayCount=\(arrayCount), insertAt=\(index)")

        isInternalUpdate = true

        if side == .left {
            if index <= leftLines.count {
                leftLines.insert(withText, at: index)
                leftContent = leftLines.joined(separator: "\n")
                // Set focus to newly inserted line (line number = index + 1 since 1-based)
                focusedLine = (side: .left, lineNumber: index + 1)
                logger.info("insertLineBelow: Inserted on left. New count: \(leftLines.count), focus line: \(index + 1)")
            } else {
                logger.error("insertLineBelow: Index \(index) out of bounds for left array of size \(leftLines.count)")
            }
        } else {
            if index <= rightLines.count {
                rightLines.insert(withText, at: index)
                rightContent = rightLines.joined(separator: "\n")
                focusedLine = (side: .right, lineNumber: index + 1)
            }
        }

        DispatchQueue.main.async {
            isInternalUpdate = false
        }

        // Trigger immediate diff recalculation for new line
        debounceWorkItem?.cancel()
        onContentChanged()
    }

    private func deleteLine(lineNumber: Int?, side: DiffSide) {
        guard let num = lineNumber else { return }
        let index = num - 1  // Convert 1-based to 0-based

        isInternalUpdate = true

        if side == .left {
            if index < leftLines.count && leftLines.count > 1 {
                leftLines.remove(at: index)
                leftContent = leftLines.joined(separator: "\n")
            }
        } else {
            if index < rightLines.count && rightLines.count > 1 {
                rightLines.remove(at: index)
                rightContent = rightLines.joined(separator: "\n")
            }
        }

        DispatchQueue.main.async {
            isInternalUpdate = false
        }

        // Trigger immediate diff recalculation
        debounceWorkItem?.cancel()
        onContentChanged()
    }

    private func scrollToSelectedChunk(proxy: ScrollViewProxy, side: DiffSide) {
        guard let chunkIndex = selectedChunkIndex,
              chunkIndex < allChunks.count else { return }

        let chunk = allChunks[chunkIndex]
        let targetLine = side == .left ? chunk.leftRange.lowerBound : chunk.rightRange.lowerBound

        // Find the aligned line that corresponds to this target
        if let alignedLine = findAlignedLine(forLine: targetLine, side: side, operation: chunk.operation) {
            let prefix = side == .left ? "left" : "right"
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("\(prefix)-\(alignedLine.id)", anchor: .top)
            }
        }
    }

    private func findAlignedLine(forLine lineNumber: Int, side: DiffSide, operation: DiffOperation) -> AlignedLine? {
        for aligned in alignedLines {
            if aligned.operation == operation {
                let matchingLineNum = side == .left ? aligned.leftLineNumber : aligned.rightLineNumber
                if matchingLineNum == lineNumber + 1 {  // lineNumber is 0-based, leftLineNumber is 1-based
                    return aligned
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
    let wordWrap: Bool
    let isSelected: Bool
    let minWidth: CGFloat
    let paneWidth: CGFloat  // Used to constrain Text width for word wrap
    let isEditable: Bool
    let onEdit: (String) -> Void
    let onInsertLineBelow: (String) -> Void  // Called when Enter is pressed, with text for new line
    let onDeleteLine: () -> Void  // Called when delete is pressed on empty line
    var shouldFocus: Bool = false  // Whether this row should receive focus
    var onFocusHandled: (() -> Void)? = nil  // Called after focus is handled

    @State private var editText: String = ""
    @State private var originalText: String = ""  // Track original to detect real changes
    @State private var isInitialized: Bool = false

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

            // Content - editable or read-only based on permissions and word wrap
            if isPlaceholder {
                // Placeholder - not editable, just empty space
                Rectangle()
                    .fill(Color.clear)
                    .frame(minWidth: wordWrap ? 0 : minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity)
            } else if wordWrap && isEditable {
                // Word wrap mode with editing
                let textWidth = max(100, paneWidth - (showLineNumbers ? 50 : 0) - 8)
                let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                let calculatedHeight = TextHeightCalculator.height(for: editText, width: textWidth, font: monoFont)
                EditableTextView(
                    text: $editText,
                    font: monoFont,
                    textWidth: textWidth,
                    onEnterPressed: { _ in },
                    onTextChanged: { newText in
                        if isInitialized && newText != originalText {
                            onEdit(newText)
                            originalText = newText
                        }
                    },
                    onDeleteEmptyLine: {
                        if isInitialized {
                            onDeleteLine()
                        }
                    },
                    onSplitLine: { beforeText, afterText in
                        guard isInitialized else { return }
                        editText = beforeText
                        originalText = beforeText
                        onEdit(beforeText)
                        onInsertLineBelow(afterText)
                    },
                    shouldFocus: shouldFocus,
                    onFocusHandled: onFocusHandled
                )
                .frame(width: textWidth, height: calculatedHeight, alignment: .topLeading)
                .onAppear {
                    let t = text ?? ""
                    editText = t
                    originalText = t
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isInitialized = true
                    }
                }
                .onChange(of: text) { _, newValue in
                    let t = newValue ?? ""
                    if editText != t {
                        editText = t
                    }
                    originalText = t
                }
            } else if wordWrap {
                // Word wrap mode read-only - use Text
                let textWidth = max(100, paneWidth - (showLineNumbers ? 50 : 0) - 8)
                Text(text ?? "")
                    .font(.system(size: fontSize, design: .monospaced))
                    .lineLimit(nil)
                    .frame(width: textWidth, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.vertical, 2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isEditable {
                // Editable TextField (no word wrap - horizontal scroll)
                EditableTextField(
                    text: $editText,
                    font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    wordWrap: false,
                    onEnterPressed: { cursorPos in
                        guard isInitialized else { return }
                        // Split text at cursor position
                        let currentText = editText
                        let splitIndex = currentText.index(currentText.startIndex, offsetBy: min(cursorPos, currentText.count))
                        let beforeCursor = String(currentText[..<splitIndex])
                        let afterCursor = String(currentText[splitIndex...])

                        // Update current line with text before cursor
                        editText = beforeCursor
                        originalText = beforeCursor
                        onEdit(beforeCursor)

                        // Insert new line with text after cursor
                        onInsertLineBelow(afterCursor)
                    },
                    onTextChanged: { newText in
                        if isInitialized && newText != originalText {
                            onEdit(newText)
                            originalText = newText
                        }
                    },
                    onDeleteEmptyLine: {
                        if isInitialized {
                            onDeleteLine()
                        }
                    },
                    shouldFocus: shouldFocus,
                    onFocusHandled: onFocusHandled
                )
                .frame(minWidth: minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity, minHeight: lineHeight)
                .padding(.leading, 4)
                .onAppear {
                    let t = text ?? ""
                    editText = t
                    originalText = t
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isInitialized = true
                    }
                }
                .onChange(of: text) { _, newValue in
                    let t = newValue ?? ""
                    if editText != t {
                        editText = t
                    }
                    originalText = t
                }
            } else {
                // Read-only Text (no word wrap)
                Text(text ?? "")
                    .font(.system(size: fontSize, design: .monospaced))
                    .frame(minWidth: minWidth - (showLineNumbers ? 47 : 0), maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
        }
        .frame(minWidth: wordWrap ? 0 : minWidth, minHeight: lineHeight, maxHeight: wordWrap ? .infinity : lineHeight)
        .background(backgroundColor)
    }
}

struct DiffToolbar: View {
    @ObservedObject var viewModel: ComparisonViewModel
    @Binding var wordWrap: Bool
    @StateObject private var undoRedoManager = UndoRedoManager()

    var body: some View {
        HStack {
            // Navigation - First/Previous/Next/Last
            Button(action: { viewModel.firstChunk() }) {
                Image(systemName: "chevron.up.2")
            }
            .disabled(viewModel.chunks.isEmpty || viewModel.currentChunkIndex == 0)
            .help("First change (⌥⌘↑)")
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button(action: { viewModel.previousChunk() }) {
                Image(systemName: "chevron.up")
            }
            .disabled(!viewModel.hasPreviousChunk)
            .help("Previous change (⌘↑)")
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button(action: { viewModel.nextChunk() }) {
                Image(systemName: "chevron.down")
            }
            .disabled(!viewModel.hasNextChunk)
            .help("Next change (⌘↓)")
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button(action: { viewModel.lastChunk() }) {
                Image(systemName: "chevron.down.2")
            }
            .disabled(viewModel.chunks.isEmpty || viewModel.currentChunkIndex == viewModel.chunks.count - 1)
            .help("Last change (⌥⌘↓)")
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Text("\(viewModel.currentChunkIndex + 1) of \(viewModel.chunks.count) changes")
                .foregroundColor(.secondary)
                .font(.caption)

            Spacer()

            // Edit actions - using UndoRedoManager for proper NSTextView integration
            Button(action: { undoRedoManager.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!undoRedoManager.canUndo)
            .help("Undo (⌘Z)")
            .keyboardShortcut("z", modifiers: .command)

            Button(action: { undoRedoManager.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!undoRedoManager.canRedo)
            .help("Redo (⌘⇧Z)")
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()
                .frame(height: 16)

            // Word wrap toggle
            Button(action: { wordWrap.toggle() }) {
                Image(systemName: wordWrap ? "text.alignleft" : "arrow.left.and.right.text.vertical")
            }
            .help(wordWrap ? "Disable word wrap (⌘W)" : "Enable word wrap (⌘W)")
            .keyboardShortcut("w", modifiers: .command)

            Divider()
                .frame(height: 16)

            // File actions
            Button(action: {
                Task {
                    try? await viewModel.saveAll()
                }
            }) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save all (⌘S)")
            .keyboardShortcut("s", modifiers: .command)

            Button(action: {
                Task {
                    await viewModel.loadAndDiff()
                }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
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
