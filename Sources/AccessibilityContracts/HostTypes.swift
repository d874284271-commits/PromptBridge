import Foundation

public struct InputIdentity: Codable, Equatable, Sendable {
    public let host: String
    public let bundleIdentifier: String?
    public let window: String
    public let input: String
    public let session: String

    public init(host: String, window: String, input: String, session: String, bundleIdentifier: String? = nil) {
        self.host = host
        self.bundleIdentifier = bundleIdentifier
        self.window = window
        self.input = input
        self.session = session
    }
}

public enum CaptureScope: String, Codable, Equatable, Sendable {
    case selection
    case entireInput
}

/// A revision must increase even when an edit is undone or the user switches away and back.
public struct InputSnapshot: Codable, Equatable, Sendable {
    public let identity: InputIdentity
    public let revision: UInt64
    public let selection: NSRange
    public let selectedText: String
    public let isComposing: Bool
    public let containsProtectedContent: Bool
    public let supportsDirectFill: Bool
    public let captureScope: CaptureScope
    public let fullText: String?
    /// Optional host metadata. Manual replacement does not require a conversation ID.
    public let contextID: String?
    public let captureID: UUID?

    public init(identity: InputIdentity, revision: UInt64, selection: NSRange,
                selectedText: String, isComposing: Bool = false,
                containsProtectedContent: Bool = false, supportsDirectFill: Bool = true,
                captureScope: CaptureScope = .selection, fullText: String? = nil,
                contextID: String? = nil, captureID: UUID? = nil) {
        self.identity = identity
        self.revision = revision
        self.selection = selection
        self.selectedText = selectedText
        self.isComposing = isComposing
        self.containsProtectedContent = containsProtectedContent
        self.supportsDirectFill = supportsDirectFill
        self.captureScope = captureScope
        self.fullText = fullText
        self.contextID = contextID
        self.captureID = captureID
    }
    private enum CodingKeys: String, CodingKey {
        case identity, revision, selection, selectedText, isComposing, containsProtectedContent
        case supportsDirectFill, captureScope, fullText, contextID, captureID
    }
    private struct WireRange: Codable {
        let location: Int
        let length: Int
        func validate() throws {
            guard location >= 0, length >= 0, location <= Int.max - length else {
                throw BrokerContractError.invalidMessage
            }
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let range = try c.decode(WireRange.self, forKey: .selection)
        try range.validate()
        self.init(identity: try c.decode(InputIdentity.self, forKey: .identity),
            revision: try c.decode(UInt64.self, forKey: .revision),
            selection: NSRange(location: range.location, length: range.length),
            selectedText: try c.decode(String.self, forKey: .selectedText),
            isComposing: try c.decode(Bool.self, forKey: .isComposing),
            containsProtectedContent: try c.decode(Bool.self, forKey: .containsProtectedContent),
            supportsDirectFill: try c.decode(Bool.self, forKey: .supportsDirectFill),
            captureScope: try c.decode(CaptureScope.self, forKey: .captureScope),
            fullText: try c.decodeIfPresent(String.self, forKey: .fullText),
            contextID: try c.decodeIfPresent(String.self, forKey: .contextID),
            captureID: try c.decodeIfPresent(UUID.self, forKey: .captureID))
    }
    public func encode(to encoder: Encoder) throws {
        let range = WireRange(location: selection.location, length: selection.length)
        try range.validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity); try c.encode(revision, forKey: .revision)
        try c.encode(range, forKey: .selection); try c.encode(selectedText, forKey: .selectedText)
        try c.encode(isComposing, forKey: .isComposing); try c.encode(containsProtectedContent, forKey: .containsProtectedContent)
        try c.encode(supportsDirectFill, forKey: .supportsDirectFill); try c.encode(captureScope, forKey: .captureScope)
        try c.encodeIfPresent(fullText, forKey: .fullText); try c.encodeIfPresent(contextID, forKey: .contextID)
        try c.encodeIfPresent(captureID, forKey: .captureID)
    }

}

public enum ReplacementStage: String, Codable, Equatable, Sendable {
    case returning
    case writing
    case verifying
}

public struct ReplacementReceipt: Codable, Equatable, Sendable {
    public let expected: InputSnapshot
    public let writtenText: String

    public init(expected: InputSnapshot, writtenText: String) {
        self.expected = expected
        self.writtenText = writtenText
    }
}

public enum FillError: String, Codable, Sendable, Error {
    case targetChanged
    case compositionActive
    case protectedContent
    case notEditable
    case cancelled
    case outcomeUnknown
    case clipboardUnavailable, clipboardChanged, selectionUnavailable
}

@MainActor public protocol HostInput: AnyObject {
    /// Display-only cached state for remote hosts.
    func snapshot() -> InputSnapshot?
    /// Real-time authorization and identity validation for every external decision.
    func liveSnapshot() async -> InputSnapshot?
    /// Revalidate immediately before writing, verify the result, and never send.
    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt
}


public extension HostInput {
    /// Local manual/Demo implementations complete immediately; remote clients override.
    func liveSnapshot() async -> InputSnapshot? { snapshot() }
}
public enum LauncherMode: String, CaseIterable, Codable, Sendable { case persistent, focusedInput }

public enum ExternalInputError: String, Codable, Sendable, Error, LocalizedError {
    case permissionRequired, unsupportedApplication, noFocusedInput
    case secureInput, noSelection, invalidSelection, unavailable, monitoringUnavailable, compositionActive
    case writeOutcomeUnknown

    public var userMessage: String {
        switch self {
        case .permissionRequired:
            "PromptBridge Accessibility 尚未获得辅助功能权限。请打开权限说明，检查组件状态并开启权限。"
        case .unsupportedApplication:
            "请先点击原应用的文本输入框，再读取文字；Terminal 请使用 CLI 接入。"
        case .noFocusedInput:
            "没有找到当前窗口中的可编辑文本输入框。"
        case .compositionActive:
            "输入法正在选字，请确认或取消候选后再翻译。"
        case .secureInput:
            "无法读取受保护的输入框，请选择普通文本输入框。"
        case .noSelection:
            "输入框或所选内容为空，请先输入要翻译的文字。"
        case .invalidSelection:
            "输入框内容已变化或无法完整读取，请重新聚焦后再试。"
        case .unavailable:
            "无法读取当前输入框，请确认窗口仍可用后重新聚焦。"
        case .monitoringUnavailable:
            "无法监听输入框的变化，请重新打开目标窗口后再试。"
        case .writeOutcomeUnknown:
            "无法确认是否已写入，请先检查原输入框中的内容。"
        }
    }

    public var errorDescription: String? { userMessage }
}

