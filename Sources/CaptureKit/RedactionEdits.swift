import CoreGraphics

/// The user's manual changes on top of auto-redact for one capture: click a block to show
/// that text again, click any word to hide it, drag to draw a box.
/// All rects are capture pixels with a top-left origin.
public struct RedactionEdits: Equatable {
    /// Auto-redact matches the user chose to show again.
    public private(set) var revealedAuto: [CGRect] = []
    /// Words the user clicked and boxes they drew.
    public private(set) var added: [RedactRegion] = []

    public init() {}

    public var isEmpty: Bool { revealedAuto.isEmpty && added.isEmpty }

    /// What actually gets covered: auto matches minus revealed ones, plus additions.
    public func effective(auto: [RedactRegion]) -> [RedactRegion] {
        auto.filter { !revealedAuto.contains($0.rect) } + added
    }

    /// Handles a click at `point`. Returns false when the click hit nothing.
    /// Priority: the user's own blocks, then auto matches, then plain words.
    @discardableResult
    public mutating func click(at point: CGPoint, auto: [RedactRegion], words: [RedactRegion]) -> Bool {
        if let index = added.lastIndex(where: { $0.coveredRect.contains(point) }) {
            added.remove(at: index)
            return true
        }
        if let match = auto.first(where: { $0.coveredRect.contains(point) }) {
            if let index = revealedAuto.firstIndex(of: match.rect) {
                revealedAuto.remove(at: index)
            } else {
                revealedAuto.append(match.rect)
            }
            return true
        }
        if let word = words.first(where: { $0.coveredRect.contains(point) }) {
            added.append(word)
            return true
        }
        return false
    }

    /// Adds a drawn box. Tiny drags (5 pt or less each way) are ignored.
    @discardableResult
    public mutating func addBox(_ rect: CGRect, minimumSize: CGFloat = 5) -> Bool {
        let box = rect.standardized
        guard box.width > minimumSize, box.height > minimumSize else { return false }
        added.append(RedactRegion(rect: box, category: nil, text: ""))
        return true
    }
}
