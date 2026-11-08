#if PROMPTBRIDGE_TESTING
import AppKit
import DraftCore

private let protectedReference = NSAttributedString.Key("PromptBridgeProtectedReference")

@MainActor final class DemoHost: NSObject, HostInput, NSTextViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let editor = CompositionTextView()
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var onExternalHelp: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var session = "A"
    private var revision: UInt64 = 0
    private var loading = false
    private var documents: [String: NSAttributedString] = [:]
    private var selections: [String: NSRange] = [:]
    private var lastSelection = NSRange(location: NSNotFound, length: 0)
    private var lastComposition = false

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "PromptBridge · 测试宿主"
        window.minSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.delegate = self
        window.center()

        let title = NSTextField(labelWithString: "发送前，把表达整理好。")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "本地验证环境 · 选择一段文字，展开辅助浮窗。切换会话或修改原文，可以检查旧结果是否被拦截。")
        description.textColor = .secondaryLabelColor
        let tabs = NSSegmentedControl(labels: ["会话 A", "会话 B"], trackingMode: .selectOne,
                                      target: self, action: #selector(switchSession(_:)))
        tabs.selectedSegment = 0
        tabs.setAccessibilityLabel("测试会话")

        editor.isRichText = true
        editor.isEditable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 16)
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.compositionChanged = { [weak self] in self?.selectionOrCompositionChanged() }
        editor.setAccessibilityLabel("测试宿主草稿")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor

        let open = NSButton(title: "展开辅助浮窗", target: self, action: #selector(openPanel))
        open.bezelStyle = .rounded
        open.keyEquivalent = "t"
        open.keyEquivalentModifierMask = [.command, .shift]
        let select = NSButton(title: "选择示例句", target: self, action: #selector(selectSample))
        select.bezelStyle = .rounded
        let external = NSButton(title: "外部选区接入说明", target: self, action: #selector(showExternalHelp))
        external.bezelStyle = .rounded
        let actions = NSStackView(views: [select, open, external])
        actions.spacing = 10
        let footer = NSTextField(wrappingLabelWithString:
            "附件图标与 @引用是测试内容。回填只替换选区，可用 ⌘Z 撤销。此窗口没有发送功能。")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, description, tabs, scroll, actions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        documents["A"] = makeDocument(sentence: sampleSentence("A"))
        documents["B"] = makeDocument(sentence: sampleSentence("B"))
        loadSession()
    }

    var inputFrameOnScreen: NSRect {
        window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
    }

    func snapshot() -> InputSnapshot? {
        guard window.isVisible, !window.isMiniaturized,
              editor.isEditable, let storage = editor.textStorage else { return nil }
        let range = editor.selectedRange()
        guard range.location != NSNotFound, range.location <= storage.length,
              range.length <= storage.length - range.location else { return nil }
        var protected = false
        if range.length > 0 {
            storage.enumerateAttributes(in: range) { attributes, _, _ in
                if attributes[.attachment] != nil || attributes[protectedReference] != nil {
                    protected = true
                }
            }
        } else if range.location > 0 && range.location < storage.length {
            // Insertion inside a reference would damage the reference as well.
            protected = storage.attribute(protectedReference, at: range.location - 1, effectiveRange: nil) != nil
                && storage.attribute(protectedReference, at: range.location, effectiveRange: nil) != nil
        }
        return InputSnapshot(
            identity: InputIdentity(host: "local-fixture", window: "demo-window", input: "draft", session: session),
            revision: revision, selection: range,
            selectedText: (storage.string as NSString).substring(with: range),
            isComposing: editor.hasMarkedText(), containsProtectedContent: protected
        )
    }

    func liveSnapshot() async -> InputSnapshot? { snapshot() }

    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt {
        guard let current = snapshot() else { throw FillError.notEditable }
        guard !current.isComposing else { throw FillError.compositionActive }
        guard !current.containsProtectedContent else { throw FillError.protectedContent }
        guard current == expected else { throw FillError.targetChanged }
        guard editor.shouldChangeText(in: current.selection, replacementString: text) else {
            throw FillError.notEditable
        }
        // Native insertion preserves surrounding attributed content and the host undo stack.
        var attributes = editor.typingAttributes
        attributes.removeValue(forKey: protectedReference)
        attributes.removeValue(forKey: .attachment)
        editor.insertText(NSAttributedString(string: text, attributes: attributes), replacementRange: current.selection)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        return ReplacementReceipt(expected: expected, writtenText: text)
    }

    func textDidChange(_ notification: Notification) { changed() }
    func textViewDidChangeSelection(_ notification: Notification) { selectionOrCompositionChanged() }
    func windowDidMove(_ notification: Notification) { onGeometryChange?() }
    func windowDidResize(_ notification: Notification) { onGeometryChange?() }
    func windowWillMiniaturize(_ notification: Notification) {
        changed()
        onVisibilityChange?(false)
    }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?(true) }
    func windowWillClose(_ notification: Notification) {
        changed()
        onVisibilityChange?(false)
    }

    private func changed() {
        guard !loading else { return }
        revision += 1
        onChange?()
    }

    private func selectionOrCompositionChanged() {
        guard !loading else { return }
        let range = editor.selectedRange()
        let composing = editor.hasMarkedText()
        guard range != lastSelection || composing != lastComposition else { return }
        lastSelection = range
        lastComposition = composing
        changed()
    }

    @objc private func switchSession(_ sender: NSSegmentedControl) {
        let next = sender.selectedSegment == 0 ? "A" : "B"
        guard next != session else { return }
        // Commit a marked range before changing the fixture document.
        editor.unmarkText()
        documents[session] = editor.attributedString()
        selections[session] = editor.selectedRange()
        session = next
        loadSession()
        window.makeFirstResponder(editor)
    }

    private func loadSession() {
        loading = true
        if let document = documents[session] { editor.textStorage?.setAttributedString(document) }
        let range = selections[session] ?? (editor.string as NSString).range(of: sampleSentence(session))
        editor.setSelectedRange(range)
        editor.undoManager?.removeAllActions()
        lastSelection = editor.selectedRange()
        lastComposition = editor.hasMarkedText()
        loading = false
        changed()
    }

    @objc private func openPanel() { onOpen?() }
    @objc private func showExternalHelp() { onExternalHelp?() }

    @objc private func selectSample() {
        let range = (editor.string as NSString).range(of: sampleSentence(session))
        if range.location != NSNotFound {
            window.makeFirstResponder(editor)
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
        }
    }

    private func sampleSentence(_ session: String) -> String {
        session == "A" ? "请保留按钮文案“确认删除”和路径 ./src/登录.ts。" : "修复登录失败的问题，并补充必要的测试。"
    }

    private func makeDocument(sentence: String) -> NSAttributedString {
        let body = NSMutableAttributedString(string: "\(sentence)\n\n附件： ")
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "示例附件") {
            image.size = NSSize(width: 22, height: 26)
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
        body.append(NSAttributedString(attachment: attachment))
        body.append(NSAttributedString(string: "  fixture.txt\n引用： "))
        body.append(NSAttributedString(string: "@示例文件", attributes: [
            protectedReference: true, .foregroundColor: NSColor.systemIndigo,
            .backgroundColor: NSColor.systemIndigo.withAlphaComponent(0.09),
        ]))
        body.addAttributes([.font: NSFont.systemFont(ofSize: 16)], range: NSRange(location: 0, length: body.length))
        return body
    }
}

#endif
