import AppKit
import SwiftUI

enum EditorRole: Hashable { case source, output }

/// Reports marked-text transitions as well as committed edits.
final class CompositionTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var compositionChanged: (() -> Void)?
    var focusChanged: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    private var measuredHeight: CGFloat = 0

    override func layout() {
        super.layout()
        reportContentHeight()
    }

    func reportContentHeight() {
        guard let textContainer, let layoutManager else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
        guard abs(height - measuredHeight) > 0.5 else { return }
        measuredHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.measuredHeight - height) <= 0.5 else { return }
            self.contentHeightChanged?(height)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?() }
        return accepted
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        compositionChanged?()
    }
}

struct NativeEditor: NSViewRepresentable {
    let value: String
    let documentID: UUID
    var isEditable = true
    var onFocus: ((NSTextView) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var role: EditorRole?
    var onRegister: ((EditorRole, UUID, NSTextView?) -> Void)?
    var onSelectionChange: ((NSTextView) -> Void)?
    let onChange: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = CompositionTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.focusChanged = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor else { return }
            coordinator?.onFocus?(editor)
        }
        editor.compositionChanged = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor else { return }
            coordinator?.onChange(editor.string, editor.hasMarkedText())
        }
        editor.contentHeightChanged = { [weak coordinator = context.coordinator] in coordinator?.onHeightChange?($0) }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CompositionTextView else { return }
        context.coordinator.onChange = onChange
        context.coordinator.onFocus = onFocus
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onSelectionChange = onSelectionChange
        if context.coordinator.documentID != documentID || context.coordinator.role != role {
            if let oldRole = context.coordinator.role, let oldDocument = context.coordinator.documentID {
                context.coordinator.onRegister?(oldRole, oldDocument, nil)
            }
        }
        context.coordinator.role = role
        context.coordinator.onRegister = onRegister
        editor.isEditable = isEditable
        if context.coordinator.documentID != documentID && !editor.hasMarkedText() {
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            context.coordinator.documentID = documentID
        }
        if editor.string != value && !editor.hasMarkedText() {
            editor.string = value
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        if let role { onRegister?(role, documentID, editor) }
        DispatchQueue.main.async { [weak editor] in editor?.reportContentHeight() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let role = coordinator.role, let documentID = coordinator.documentID {
            coordinator.onRegister?(role, documentID, nil)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String, Bool) -> Void
        var onFocus: ((NSTextView) -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var documentID: UUID?
        var role: EditorRole?
        var onRegister: ((EditorRole, UUID, NSTextView?) -> Void)?
        var onSelectionChange: ((NSTextView) -> Void)?
        init(onChange: @escaping (String, Bool) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            onChange(editor.string, editor.hasMarkedText())
            (editor as? CompositionTextView)?.reportContentHeight()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            onSelectionChange?(editor)
        }
    }
}
