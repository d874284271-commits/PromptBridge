import Foundation

/// Each editor grows independently; only the excess above the readable minimum
/// shares the remaining window space. Tiny screens scroll the middle form.
public enum EditorLayout {
    public static func heights(source: CGFloat, output: CGFloat?, available: CGFloat) -> (source: CGFloat, output: CGFloat) {
        let source = min(220, max(72, source.isFinite ? source : 72))
        guard let output else { return (min(source, max(72, available)), 0) }
        let result = min(220, max(72, output.isFinite ? output : 72))
        let extra = source + result - 144
        guard extra > 0 else { return (72, 72) }
        let scale = min(1, max(0, available - 144) / extra)
        return (72 + (source - 72) * scale, 72 + (result - 72) * scale)
    }
}
