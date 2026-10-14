import AppKit
import Foundation

/// Resource lookup.
///
/// Inside the assembled `.app` every asset sits in `Contents/Resources` and
/// `Bundle.main` finds it. When the binary is run straight from `.build` (for
/// example `swift run`), the repository's `Resources` folder is used instead.
enum Assets {
    static func url(named name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The fan glyph for the menu bar. Loaded as a template image so macOS
    /// renders it black on light bars and white on dark ones.
    static func menuBarIcon() -> NSImage? {
        guard let url = url(named: "MenuBarIcon", extension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 20, height: 18)
        return image
    }

    /// Product art shown at the top of the popover.
    static func heroImage() -> NSImage? {
        url(named: "FanHero", extension: "png").flatMap(NSImage.init(contentsOf:))
    }

    /// Wide banner used behind the control panel header. Two plates ship, one
    /// per appearance, because the art sits on a coloured ground rather than
    /// on the panel itself.
    static func bannerImage(dark: Bool) -> NSImage? {
        let name = dark ? "FanBannerDark" : "FanBanner"
        if let image = url(named: name, extension: "png").flatMap(NSImage.init(contentsOf:)) {
            return image
        }
        // Fall back to whichever plate did get built.
        return url(named: dark ? "FanBanner" : "FanBannerDark", extension: "png")
            .flatMap(NSImage.init(contentsOf:))
    }

    /// Returns a copy drawn at `opacity`, used to signal on/off/offline state
    /// in the menu bar without shipping a second asset.
    static func dimmed(_ image: NSImage, opacity: CGFloat) -> NSImage {
        guard opacity < 1 else { return image }
        let size = image.size
        let dimmed = NSImage(size: size, flipped: false) { rect in
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: opacity
            )
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}
