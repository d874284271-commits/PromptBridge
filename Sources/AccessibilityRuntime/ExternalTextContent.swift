import Foundation

/// The observed text-only AX tree in the supported host builds. Walks only the
/// captured input's descendants; a missing children array is not an empty array.
@MainActor enum ExternalTextContent {
    struct Node<Element> {
        let pid: pid_t
        let role: String
        let children: [Element]
    }

    static func containsObjects<Element>(root: Element, pid: pid_t,
        same: (Element, Element) -> Bool,
        read: (Element) throws -> Node<Element>) -> Bool? {
        var pending: [(Element, Bool)] = [(root, true)]
        var seen: [Element] = []
        var sawText = false
        let deadline = Date().addingTimeInterval(0.5)
        do {
            while let (element, isRoot) = pending.popLast() {
                guard seen.count < 256, Date() < deadline,
                      !seen.contains(where: { same($0, element) }) else { return nil }
                seen.append(element)
                let node = try read(element)
                guard node.pid == pid, Date() < deadline else { return nil }
                if isRoot {
                    guard node.role == "AXTextArea" || node.role == "AXTextField" else { return nil }
                    // The editable root itself is text evidence. Its scroll bar is
                    // control chrome, not an embedded object in the document.
                    sawText = true
                } else if node.role == "AXScrollBar" {
                    continue
                } else if node.role == "AXStaticText" {
                    sawText = true
                } else if node.role != "AXGroup" {
                    return true
                }
                guard node.children.count <= 256 - seen.count - pending.count else { return nil }
                pending.append(contentsOf: node.children.map { ($0, false) })
            }
            return sawText ? false : nil
        } catch { return nil }
    }
}
