// SpriteSheet.swift — loads a bundled 4×4 mood/animation sprite sheet and
// crops individual frames. Rows are moods (happy/neutral/tired/stressed),
// columns are idle-cycle frames. Sheets are processed transparent PNGs in
// Sources/Lens/Resources (see scripts that build them from the design grids).

import CoreGraphics
import ImageIO
import Foundation

struct SpriteSheet {
    let image: CGImage
    let cols: Int
    let rows: Int

    var frameWidth: Int { image.width / cols }
    var frameHeight: Int { image.height / rows }

    /// Crop the frame at (row, col), clamped to the grid.
    func frame(row: Int, col: Int) -> CGImage? {
        let r = min(max(row, 0), rows - 1)
        let c = min(max(col, 0), cols - 1)
        let rect = CGRect(x: c * frameWidth, y: r * frameHeight,
                          width: frameWidth, height: frameHeight)
        return image.cropping(to: rect)
    }
}

/// Loads sheets once and memoizes them. Accessed from views on the main thread.
enum SpriteSheetStore {
    private static var cache: [String: SpriteSheet?] = [:]

    static func sheet(named name: String, cols: Int = 4, rows: Int = 4) -> SpriteSheet? {
        if let hit = cache[name] { return hit }
        let loaded = load(name: name, cols: cols, rows: rows)
        cache[name] = loaded
        return loaded
    }

    private static func load(name: String, cols: Int, rows: Int) -> SpriteSheet? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png",
                                          subdirectory: "Resources"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return SpriteSheet(image: img, cols: cols, rows: rows)
    }
}
