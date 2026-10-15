// Draws the OpenBerg app icon and writes it as an .icns.
//
//   swift Tools/GenerateAppIcon.swift /path/to/AppIcon.icns
//
// The icon is a black macOS squircle with a white "oB", drawn with SwiftUI
// at 1024px and downscaled through every size the iconset needs. Nothing is
// committed as art: scripts/build-app.sh runs this at build time, so the
// bundle's only image is generated from this file.

import AppKit
import SwiftUI

private struct IconArt: View {
    var body: some View {
        ZStack {
            // The standard macOS icon grid: an 824pt squircle on a 1024
            // canvas, so the icon sits correctly beside Apple's own.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color.black)
                .frame(width: 824, height: 824)

            Text("oB")
                .font(.system(size: 420, weight: .semibold))
                .tracking(-8)
                .foregroundStyle(.white)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
private func renderBase() throws -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: IconArt())
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "ImageRenderer produced no image"])
    }
    return NSBitmapImageRep(cgImage: cgImage)
}

private func downscale(_ image: NSImage, to size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

@MainActor
private func generate(to outputPath: String) throws {
    let fileManager = FileManager.default

    let base = try renderBase()
    guard let basePNG = base.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not encode the 1024px icon"])
    }
    guard let baseImage = NSImage(data: basePNG) else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not reload the 1024px icon"])
    }

    let iconset = fileManager.temporaryDirectory
        .appendingPathComponent("OpenBerg-\(UUID().uuidString).iconset")
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconset) }

    let entries: [(name: String, size: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for entry in entries {
        let url = iconset.appendingPathComponent("\(entry.name).png")
        if entry.size == 1024 {
            try basePNG.write(to: url)
        } else if let data = downscale(baseImage, to: entry.size) {
            try data.write(to: url)
        } else {
            throw NSError(domain: "GenerateAppIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not render \(entry.size)px"])
        }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift Tools/GenerateAppIcon.swift <output.icns>\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    do {
        try generate(to: arguments[1])
        print("==> Icon written: \(arguments[1])")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
