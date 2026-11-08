import Foundation
import AccessibilityContracts

/// The result of the narrow, read-only capability gate for an external host.
/// A document candidate being present is evidence to report, not permission to write.
struct ExternalReplacementCapabilities: Equatable, Sendable {
    /// Host eligibility only. The current input must separately pass runtime checks.
    static func permitsRuntimeCheck(_ application: ExternalApplication) -> Bool {
        application.bundle != BrokerIdentity.bundle && application.bundle != BrokerIdentity.clientBundle && application.bundle != "com.apple.Terminal"
    }

    /// Historical synthetic evidence, separate from current input capability and
    /// final package acceptance. Unknown host versions may still pass at runtime.
    @MainActor static func hasReplacementEvidence(_ application: ExternalApplication) -> Bool {
        if application.bundle == CodexCapabilityProbe.bundleIdentifier {
            return application.version == "26.930.51102" && application.build == "13100"
        }
        return application.bundle == "com.anthropic.claudefordesktop"
            && ((application.version == "2.19675.0" && application.build == "2.19675.0")
                || (application.version == "2.19675.1" && application.build == "2.19675.1"))
    }

    let contextCandidatePresent: Bool
    let approved: Bool
    /// nil: unable to classify; true: structured/non-text descendants; false: text-only.
    let protectedContent: Bool?
    let explanation: String

    static let unavailable = ExternalReplacementCapabilities(
        contextCandidatePresent: false,
        approved: false,
        protectedContent: nil,
        explanation: "当前输入框没有可核验的全文回填能力，或包含无法识别的嵌入内容。")
}
