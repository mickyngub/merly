import Foundation

struct DragReorder: Equatable {
    let id: String
    let originalOrderedIDs: [String]
    let heights: [String: CGFloat]
    let spacing: CGFloat
    let originalTop: CGFloat
    private let slotTops: [CGFloat]
    private(set) var insertionIndex: Int
    private(set) var offset: CGFloat = 0

    init?(id: String, orderedIDs: [String], heights: [String: CGFloat], spacing: CGFloat) {
        guard let originalIndex = orderedIDs.firstIndex(of: id),
              Set(orderedIDs).count == orderedIDs.count,
              spacing.isFinite, spacing >= 0,
              orderedIDs.allSatisfy({
                  guard let height = heights[$0] else { return false }
                  return height.isFinite && height > 0
              }) else { return nil }

        var tops: [CGFloat] = [0]
        for otherID in orderedIDs where otherID != id {
            guard let height = heights[otherID], let previousTop = tops.last else { return nil }
            let nextTop = previousTop + height + spacing
            guard nextTop.isFinite else { return nil }
            tops.append(nextTop)
        }
        self.id = id
        self.originalOrderedIDs = orderedIDs
        self.heights = heights
        self.spacing = spacing
        self.originalTop = tops[originalIndex]
        self.slotTops = tops
        self.insertionIndex = originalIndex
    }

    var orderedIDs: [String] {
        var result = originalOrderedIDs.filter { $0 != id }
        result.insert(id, at: insertionIndex)
        return result
    }

    var slotTop: CGFloat { slotTops[insertionIndex] }

    mutating func update(translation: CGFloat) {
        let desiredTop = originalTop + translation
        guard translation.isFinite, desiredTop.isFinite else { return }

        while insertionIndex + 1 < slotTops.count {
            let distance = slotTops[insertionIndex + 1] - slotTops[insertionIndex]
            let boundary = slotTops[insertionIndex] + distance / 2
            guard desiredTop > boundary + min(6, distance * 0.1) else { break }
            insertionIndex += 1
        }
        while insertionIndex > 0 {
            let distance = slotTops[insertionIndex] - slotTops[insertionIndex - 1]
            let boundary = slotTops[insertionIndex - 1] + distance / 2
            guard desiredTop < boundary - min(6, distance * 0.1) else { break }
            insertionIndex -= 1
        }
        offset = desiredTop - slotTop
    }
}
