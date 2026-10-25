import Foundation

/// PNGs shipped in the SwiftPM resource bundle. `Bundle.module` alone only looks
/// at the .app root and the absolute build directory baked in at compile time, so
/// an installed app crashed once the checkout it was built from was deleted.
/// `scripts/bundle.sh` places the bundle in `Contents/Resources`; dev runs and
/// tests fall through to `Bundle.module`.
enum BundledArt {
    private static let bundle: Bundle = {
        if let dir = Bundle.main.resourceURL,
           let packed = Bundle(url: dir.appendingPathComponent("Merly_Merly.bundle")) {
            return packed
        }
        return .module
    }()

    static func url(_ name: String) -> URL? {
        bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
    }
}
