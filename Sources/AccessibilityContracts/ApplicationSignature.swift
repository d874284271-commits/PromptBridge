import Foundation
import Security

public enum ApplicationSignature {
    /// Validates the complete bundle against an already trusted signer.
    public static func verify(_ url: URL, bundle: String, certificate: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = try BrokerIdentity.requirement(bundle: bundle, certificate: certificate)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess,
              Bundle(url: url)?.bundleIdentifier == bundle else { throw BrokerContractError.invalidIdentity }
    }
}
