import AppKit
import SwiftUI

@MainActor enum BrandAssets {
    static let appIcon = load("AppIcon")

    static let menuBarIcon: NSImage? = {
        guard let image = load("MenuBarTemplate") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 22, height: 22 * image.size.height / image.size.width)
        return image
    }()

    private static func load(_ name: String) -> NSImage? {
        var url = Bundle.main.url(forResource: name, withExtension: "png")
        #if DEBUG || PROMPTBRIDGE_TESTING
        if url == nil { url = Bundle.module.url(forResource: name, withExtension: "png") }
        #endif
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}

struct BrandMark: View {
    var body: some View {
        Group {
            if let image = BrandAssets.appIcon {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "character.bubble.fill").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}
