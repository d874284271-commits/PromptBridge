import AppKit
import ApplicationServices
import Carbon
import os
import AccessibilityContracts

/// Fixed Terminal dictionary vocabulary. No script source, do-script event,
/// contents/history/title property or arbitrary key API is accepted here.
@MainActor public final class NativeCLITerminalAccess: CLITerminalAccess {
    private let logger = Logger(subsystem: "local.promptbridge.accessibility", category: "CLI")
    public init() {}
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    public func process(_ pid: Int32) -> CLIProcessSnapshot? { CLIProcessSnapshot.inspect(pid: pid) }
    public func terminalProcess() -> CLIProcessSnapshot? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first else { return nil }
        return process(app.processIdentifier)
    }
    public var automationPermission: CLIAutomationPermission { Self.automationPermission(ask: false) }
    public static func automationPermission(ask: Bool) -> CLIAutomationPermission {
        let address = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        let code = AEDeterminePermissionToAutomateTarget(address.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch code {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unavailable
        }
    }
    private enum Property: OSType { case id = 0x49442020, index = 0x70696478, tty = 0x74747479, selected = 0x7462736c }
    private let windowClass: OSType = 0x6377696e // cwin
    private let tabClass: OSType = 0x74746162 // ttab
    private func specifier(want: OSType, form: OSType, key: NSAppleEventDescriptor,
                           container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let spec = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw BrokerProbeFailure(code: .unavailable) }
        return spec
    }
    private func property(_ property: Property, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(want: OSType(cProperty), form: OSType(formPropertyID),
            key: NSAppleEventDescriptor(typeCode: property.rawValue), container: container)
    }
    func all(_ kind: OSType, in container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        // Absolute-position ordinals require typeAbsoluteOrdinal ('abso').
        guard let ordinal = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal),
            data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data) else {
            throw BrokerProbeFailure(code: .unavailable)
        }
        return try specifier(want: kind, form: OSType(formAbsolutePosition), key: ordinal, container: container)
    }
    private func window(_ id: Int32) throws -> NSAppleEventDescriptor {
        try specifier(want: windowClass, form: OSType(formUniqueID), key: NSAppleEventDescriptor(int32: id))
    }
    private func send(get descriptor: NSAppleEventDescriptor, terminalPID: Int32, stage: String) throws -> NSAppleEventDescriptor {
        try send(eventID: AEEventID(kAEGetData), descriptor: descriptor, value: nil, terminalPID: terminalPID, stage: stage)
    }
    private func send(eventID: AEEventID, descriptor: NSAppleEventDescriptor,
                      value: NSAppleEventDescriptor?, terminalPID: Int32, stage: String) throws -> NSAppleEventDescriptor {
        guard automationPermission == .granted,
              let process = terminalProcess(), process.pid == terminalPID else { throw BrokerProbeFailure(code: .automationRequired) }
        let event = Self.metadataEvent(eventID: eventID, descriptor: descriptor, value: value, terminalPID: terminalPID)
        let reply: NSAppleEventDescriptor
        do { reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: 1) }
        catch {
            logger.error("CLI metadata stage=\(stage, privacy: .public) transportCode=\((error as NSError).code)")
            throw error
        }
        if let failure = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), failure.int32Value != 0 {
            logger.error("CLI metadata stage=\(stage, privacy: .public) appleEventCode=\(failure.int32Value)")
            throw BrokerProbeFailure(code: failure.int32Value == errAEEventNotPermitted ? .automationRequired : .unavailable)
        }
        let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
        // Diagnostic metadata only: never log descriptors, TTYs, titles or text.
        logger.notice("CLI metadata stage=\(stage, privacy: .public) replyType=\(result.descriptorType) items=\(result.numberOfItems)")
        return result
    }
    static func metadataEvent(eventID: AEEventID, descriptor: NSAppleEventDescriptor,
                              value: NSAppleEventDescriptor?, terminalPID: Int32) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: terminalPID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(descriptor, forKeyword: AEKeyword(keyDirectObject))
        if let value { event.setParam(value, forKeyword: AEKeyword(keyAEData)) }
        return event
    }
    private func items(_ descriptor: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == typeAEList else { throw BrokerProbeFailure(code: .unavailable) }
        guard descriptor.numberOfItems > 0 else { return [] }
        return try (1...descriptor.numberOfItems).map {
            guard let item = descriptor.atIndex($0) else { throw BrokerProbeFailure(code: .unavailable) }
            return item
        }
    }
    public func tabs(terminalPID: Int32) throws -> [CLITerminalTab] {
        let ids = try items(send(get: property(.id, of: all(windowClass)), terminalPID: terminalPID, stage: "windowIDs"))
        var result: [CLITerminalTab] = []
        for item in ids {
            let id = item.int32Value
            guard id > 0 else { throw BrokerProbeFailure(code: .unavailable) }
            let win = try window(id)
            let front = try send(get: property(.index, of: win), terminalPID: terminalPID, stage: "windowIndex").int32Value == 1
            let allTabs = try all(tabClass, in: win)
            let ttys = try items(send(get: property(.tty, of: allTabs), terminalPID: terminalPID, stage: "tabTTYs"))
            let selected = try items(send(get: property(.selected, of: allTabs), terminalPID: terminalPID, stage: "tabSelection"))
            guard ttys.count == selected.count else { throw BrokerProbeFailure(code: .targetChanged) }
            for (tty, selection) in zip(ttys, selected) {
                guard let value = tty.stringValue, value.hasPrefix("/dev/tty") else { throw BrokerProbeFailure(code: .unavailable) }
                result.append(CLITerminalTab(windowID: id, tty: value, selected: selection.booleanValue, frontWindow: front))
            }
        }
        return result
    }
    public func sendControlG(terminalPID: Int32) throws {
        guard accessibilityGranted, frontmostPID == terminalPID, terminalProcess()?.pid == terminalPID,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: false) else {
            throw BrokerProbeFailure(code: .targetChanged)
        }
        down.flags = .maskControl; up.flags = .maskControl
        down.postToPid(terminalPID); up.postToPid(terminalPID)
    }
    public func select(tty: String, windowID: Int32, terminalPID: Int32) throws {
        let win = try window(windowID)
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(kAEEquals)), forKeyword: AEKeyword(keyAECompOperator))
        guard let examined = NSAppleEventDescriptor(descriptorType: DescType(typeObjectBeingExamined), data: Data()) else {
            throw BrokerProbeFailure(code: .unavailable)
        }
        comparison.setDescriptor(try property(.tty, of: examined), forKeyword: AEKeyword(keyAEObject1))
        comparison.setDescriptor(NSAppleEventDescriptor(string: tty), forKeyword: AEKeyword(keyAEObject2))
        guard let predicate = comparison.coerce(toDescriptorType: DescType(typeCompDescriptor)) else {
            throw BrokerProbeFailure(code: .unavailable)
        }
        // Address by TTY predicate, not a cached tab index which can be reordered.
        let tab = try specifier(want: tabClass, form: OSType(formTest), key: predicate, container: win)
        _ = try send(eventID: AEEventID(kAESetData), descriptor: property(.selected, of: tab),
            value: NSAppleEventDescriptor(boolean: true), terminalPID: terminalPID, stage: "selectTab")
        _ = try send(eventID: AEEventID(kAESetData), descriptor: property(.index, of: win),
            value: NSAppleEventDescriptor(int32: 1), terminalPID: terminalPID, stage: "raiseWindow")
    }
    public func activate(terminalPID: Int32) -> Bool {
        NSRunningApplication(processIdentifier: terminalPID)?.activate(options: []) == true
    }
}
