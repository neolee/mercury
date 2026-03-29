import AppKit
import SwiftUI

struct TextEditorEx: NSViewRepresentable {
    @Binding private var text: String

    private let placeholder: String
    private let focusedBinding: Binding<Bool>?
    private let heightBinding: Binding<CGFloat>?
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let growthThresholdHeight: CGFloat
    private let font: NSFont
    private let isEditable: Bool

    init(
        text: Binding<String>,
        placeholder: String = "",
        isFocused: Binding<Bool>? = nil,
        height: Binding<CGFloat>? = nil,
        minHeight: CGFloat = 120,
        maxHeight: CGFloat = 240,
        growthThresholdHeight: CGFloat? = nil,
        font: NSFont = .preferredFont(forTextStyle: .body),
        isEditable: Bool = true
    ) {
        self._text = text
        self.placeholder = placeholder
        self.focusedBinding = isFocused
        self.heightBinding = height
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.growthThresholdHeight = max(minHeight, growthThresholdHeight ?? minHeight)
        self.font = font
        self.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TextEditorExScrollView {
        let scrollView = TextEditorExScrollView(
            minHeight: minHeight,
            maxHeight: maxHeight,
            growthThresholdHeight: growthThresholdHeight,
            font: font
        )
        scrollView.textView.delegate = context.coordinator
        scrollView.textView.string = text
        scrollView.textView.placeholderString = placeholder
        scrollView.textView.isEditable = isEditable
        scrollView.focusRequest = focusedBinding?.wrappedValue ?? false
        scrollView.onHeightChange = { height in
            context.coordinator.updateHeight(height)
        }
        scrollView.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ nsView: TextEditorExScrollView, context: Context) {
        nsView.minHeight = minHeight
        nsView.maxHeight = maxHeight
        nsView.growthThresholdHeight = growthThresholdHeight
        nsView.textView.font = font

        if nsView.textView.hasMarkedText() == false,
           nsView.textView.string != text {
            let selectedRanges = nsView.textView.selectedRanges
            nsView.textView.string = text
            if nsView.window?.firstResponder === nsView.textView {
                nsView.textView.selectedRanges = selectedRanges
            }
            nsView.textView.needsDisplay = true
        }

        if nsView.textView.placeholderString != placeholder {
            nsView.textView.placeholderString = placeholder
            nsView.textView.needsDisplay = true
        }

        if nsView.textView.isEditable != isEditable {
            nsView.textView.isEditable = isEditable
        }

        if let focusedBinding {
            nsView.updateFocusRequest(focusedBinding.wrappedValue)
        }

        nsView.recalculateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: TextEditorEx

        init(_ parent: TextEditorEx) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            if let scrollView = textView.enclosingScrollView as? TextEditorExScrollView {
                scrollView.recalculateHeight()
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            updateFocusState(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            updateFocusState(false)
        }

        func updateHeight(_ height: CGFloat) {
            guard let heightBinding else { return }
            if abs(heightBinding.wrappedValue - height) > 0.5 {
                DispatchQueue.main.async {
                    heightBinding.wrappedValue = height
                }
            }
        }

        private var heightBinding: Binding<CGFloat>? {
            parent.heightBinding
        }

        private func updateFocusState(_ isFocused: Bool) {
            guard let focusedBinding = parent.focusedBinding else { return }
            guard focusedBinding.wrappedValue != isFocused else { return }
            DispatchQueue.main.async {
                focusedBinding.wrappedValue = isFocused
            }
        }
    }
}

final class TextEditorExScrollView: NSScrollView {
    let textView: TextEditorExTextView
    var onHeightChange: ((CGFloat) -> Void)?
    var focusRequest = false

    var minHeight: CGFloat {
        didSet { recalculateHeight() }
    }

    var maxHeight: CGFloat {
        didSet { recalculateHeight() }
    }

    var growthThresholdHeight: CGFloat {
        didSet { recalculateHeight() }
    }

    init(minHeight: CGFloat, maxHeight: CGFloat, growthThresholdHeight: CGFloat, font: NSFont) {
        self.textView = TextEditorExTextView(frame: .zero)
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.growthThresholdHeight = growthThresholdHeight
        super.init(frame: .zero)

        borderType = .bezelBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true

        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.font = font
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true

        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        recalculateHeight()
    }

    func recalculateHeight() {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let contentHeight = ceil(usedHeight + (textView.textContainerInset.height * 2))
        let targetHeight: CGFloat
        if contentHeight <= growthThresholdHeight {
            targetHeight = minHeight
        } else {
            targetHeight = min(maxHeight, contentHeight)
        }
        let shouldScroll = contentHeight > maxHeight + 0.5

        if hasVerticalScroller != shouldScroll {
            hasVerticalScroller = shouldScroll
        }

        onHeightChange?(targetHeight)
    }

    func updateFocusRequest(_ isFocused: Bool) {
        if isFocused {
            guard focusRequest == false else { return }
            focusRequest = true
            requestFirstResponderWhenReady()
        } else {
            focusRequest = false
            if window?.firstResponder === textView {
                window?.makeFirstResponder(nil)
            }
        }
    }

    private func requestFirstResponderWhenReady(attemptsRemaining: Int = 8) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.focusRequest else { return }
            guard attemptsRemaining > 0 else { return }

            guard let window = self.window,
                  window.isVisible,
                  window.isKeyWindow,
                  self.textView.isEditable else {
                self.requestFirstResponderWhenReady(attemptsRemaining: attemptsRemaining - 1)
                return
            }

            if window.firstResponder !== self.textView {
                window.makeFirstResponder(self.textView)
            }
        }
    }
}

final class TextEditorExTextView: NSTextView {
    var placeholderString: String = "" {
        didSet {
            needsDisplay = true
        }
    }

    override var string: String {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, placeholderString.isEmpty == false else {
            return
        }

        let containerOrigin = textContainerOrigin
        let linePadding = textContainer?.lineFragmentPadding ?? 0
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .preferredFont(forTextStyle: .body)) ?? 0
        let placeholderRect = NSRect(
            x: containerOrigin.x + linePadding,
            y: containerOrigin.y,
            width: max(bounds.width - (containerOrigin.x * 2) - (linePadding * 2), 0),
            height: ceil(lineHeight)
        )

        placeholderString.draw(
            in: placeholderRect,
            withAttributes: [
                .font: font ?? NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}
