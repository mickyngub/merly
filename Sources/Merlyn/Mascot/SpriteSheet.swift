// SpriteSheet.swift — loads a bundled mood/animation sprite sheet and crops
// individual frames. Columns are the 4 idle-cycle frames; rows are moods in
// `Mood.spriteRow` order (up to 8 — the row count is derived from the image
// height, so taller sheets need no call-site changes). Sheets are processed
// transparent PNGs in Sources/Merlyn/Resources (see the scripts that build
// them from the design grids).

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

/// Loads sheets once and memoizes them. `@MainActor` because the cache is
/// unsynchronized shared state and every caller (views, the status item) is
/// already on the main thread; `exists`/`formSprite` stay nonisolated — they
/// are stateless URL probes safe from any thread (readers call them off-main).
@MainActor
enum SpriteSheetStore {
    private static var cache: [String: SpriteSheet?] = [:]

    static func sheet(named name: String, cols: Int = 4) -> SpriteSheet? {
        if let hit = cache[name] { return hit }
        let loaded = load(name: name, cols: cols)
        cache[name] = loaded
        return loaded
    }

    /// Whether a sheet PNG is bundled, without decoding it — a cheap URL probe
    /// safe to call from any thread (used to pick an evolution form sheet and
    /// degrade gracefully when its art isn't bundled yet).
    nonisolated static func exists(_ name: String) -> Bool {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources") != nil
    }

    /// Resolve the sprite sheet for an evolution `form` (0 = base), stepping down
    /// to the highest available lower form and finally the base sheet. Returns
    /// nil only when `base` is nil (the drawn-critter opt-out).
    nonisolated static func formSprite(base: String?, form: Int) -> String? {
        guard let base else { return nil }
        if form > 0 {
            for f in stride(from: form, through: 1, by: -1) {
                let name = "\(base)-evo\(f + 1)"   // evo2, evo3, …
                if exists(name) { return name }
            }
        }
        return base
    }

    nonisolated private static func load(name: String, cols: Int) -> SpriteSheet? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png",
                                          subdirectory: "Resources"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        // Derive row count from image dimensions so taller sheets (more moods) work
        // without any call-site changes — frame height matches frame width (square frames).
        let frameWidth = img.width / cols
        let rows = frameWidth > 0 ? img.height / frameWidth : cols
        return SpriteSheet(image: img, cols: cols, rows: rows)
    }
}

extension ProviderSnapshot {
    /// Sprite sheet for the mascot's current evolution form, degrading to the
    /// highest *available* lower form (and finally the base sheet) so the app
    /// works before any tier art is bundled. Mood still picks the row; form
    /// picks the sheet. Lives in the mascot layer (not on the snapshot's own
    /// file) because it consults the bundled art — the data layer doesn't know
    /// what's rendered.
    var resolvedSpriteForm: String? {
        SpriteSheetStore.formSprite(base: config.resolvedSprite, form: game?.form ?? 0)
    }
}
