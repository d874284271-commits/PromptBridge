import AppKit
import SwiftUI

/// One editable selector: suggestions are shortcuts, not a language whitelist.
struct LanguageComboBox: NSViewRepresentable {
    @Binding var text: String
    var onCompositionChange: (Bool) -> Void = { _ in }
    var onCommit: (String) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled
    private static let suggestions = ["English", "简体中文", "繁體中文", "日本語", "한국어", "Français", "Deutsch", "Español"]

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = false
        box.hasVerticalScroller = true
        box.numberOfVisibleItems = Self.suggestions.count
        box.addItems(withObjectValues: Self.suggestions)
        box.placeholderString = "选择或输入任意语言"
        box.font = .systemFont(ofSize: 13)
        box.setAccessibilityLabel("目标语言")
        box.delegate = context.coordinator
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        if box.stringValue != text { box.stringValue = text }
        box.isEnabled = isEnabled
        context.coordinator.updating = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: LanguageComboBox
        var updating = false
        private var editingStart = ""
        private var textWasEdited = false
        init(_ parent: LanguageComboBox) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            editingStart = box.stringValue
            textWasEdited = false
            reportComposition(box)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox else { return }
            textWasEdited = true
            reportComposition(box)
            parent.text = box.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
            parent.onCompositionChange(false)
            let shouldCommit = textWasEdited && box.stringValue != editingStart
            textWasEdited = false
            if shouldCommit { parent.onCommit(box.stringValue) }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            parent.text = value
            editingStart = value
            textWasEdited = false
            parent.onCompositionChange(false)
            parent.onCommit(value)
        }

        private func reportComposition(_ box: NSComboBox) {
            parent.onCompositionChange((box.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        }
    }
}
