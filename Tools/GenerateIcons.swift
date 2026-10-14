#!/usr/bin/env swift
//
//  GenerateIcons.swift
//  Build-time asset generator for Atomberg Fan (menu bar app).
//
//  Everything is derived from the single source image `assets/fan-asset.jpg`:
//
//    Resources/AppIcon.icns        – macOS app icon (squircle + fan)
//    Resources/MenuBarIcon.png     – 18pt template silhouette (+ @2x, @3x)
//    Resources/FanHero.png         – 256px art for the panel header chip
//    Resources/FanBanner.png       – wide hero, light appearance
//    Resources/FanBannerDark.png   – wide hero, dark appearance
//    Resources/_debug-icons.png    – contact sheet used to eyeball the result
//
//  The source is a product photo on a pure white backdrop, so the fan is
//  separated from that backdrop once and the mask is reused for both the menu
//  bar silhouette and the hero banner.
//
//  Run from the repository root:   swift Tools/GenerateIcons.swift
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("assets/fan-asset.jpg")
let outDir = root.appendingPathComponent("Resources", isDirectory: true)
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Bitmap helpers

/// A read/write view over a Core Graphics bitmap. Owns the context so the
/// backing store cannot be freed while `pixels` is still in use.
final class Bitmap {
    let context: CGContext
    let width: Int
    let height: Int
    let stride: Int
    let pixels: UnsafeMutablePointer<UInt8>

    init?(_ context: CGContext) {
        guard let raw = context.data else { return nil }
        self.context = context
        self.width = context.width
        self.height = context.height
        self.stride = context.bytesPerRow
        self.pixels = raw.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
    }

    func offset(_ x: Int, _ y: Int) -> Int { y * stride + x * 4 }

    /// Colour distance from pure white: 0 means white, 255 means black.
    func whiteness(_ x: Int, _ y: Int) -> Double {
        let o = offset(x, y)
        return 255.0 - min(Double(pixels[o]), min(Double(pixels[o + 1]), Double(pixels[o + 2])))
    }
}

func makeContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not allocate \(width)x\(height) context") }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

func loadSource() -> CGImage {
    guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("cannot read image at \(sourceURL.path)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("cannot create PNG destination at \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

/// Draws a CGImage inside a `box` (points) centred, preserving aspect ratio.
func aspectFit(_ image: CGImage, in box: CGSize) -> CGRect {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let scale = min(box.width / w, box.height / h)
    let size = CGSize(width: w * scale, height: h * scale)
    return CGRect(
        x: (box.width - size.width) / 2,
        y: (box.height - size.height) / 2,
        width: size.width, height: size.height
    )
}

// MARK: - Separating the fan from its backdrop

/// Alpha mask of the fan, plus the box it occupies in the working image.
struct SubjectMask {
    let alpha: [UInt8]
    let work: Int
    let box: CGRect
    /// Width and height of `alpha`'s array, in working pixels.
    var width: Int { work }
    var height: Int { work }
}

/// The photo is a fan on a pure white backdrop, so the subject is "whatever is
/// meaningfully darker than white, reachable in one piece". The specks are
/// filtered out, the largest blob is kept (which drops the remote control in
/// the source art), and the edges are feathered so downscaling stays smooth.
func subjectMask(from image: CGImage, work: Int = 700) -> SubjectMask {
    let bmp = rasterise(image, size: work)
    let n = work * work

    var candidate = [Bool](repeating: false, count: n)
    for y in 0..<work {
        for x in 0..<work where bmp.whiteness(x, y) > 14 {
            candidate[y * work + x] = true
        }
    }

    // Majority filter: kills JPEG speckle in the background.
    var denoised = [Bool](repeating: false, count: n)
    for y in 0..<work {
        for x in 0..<work {
            var hits = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= work || ny >= work { continue }
                    if candidate[ny * work + nx] { hits += 1 }
                }
            }
            denoised[y * work + x] = hits >= 5
        }
    }

    // Connected components; keep the biggest one.
    var label = [Int32](repeating: 0, count: n)
    var best = Int32(0), bestCount = 0
    var current = Int32(0)
    var stack: [Int] = []
    stack.reserveCapacity(4096)

    for start in 0..<n where denoised[start] && label[start] == 0 {
        current += 1
        var count = 0
        label[start] = current
        stack.removeAll(keepingCapacity: true)
        stack.append(start)
        while let idx = stack.popLast() {
            count += 1
            let x = idx % work, y = idx / work
            if x > 0, denoised[idx - 1], label[idx - 1] == 0 { label[idx - 1] = current; stack.append(idx - 1) }
            if x < work - 1, denoised[idx + 1], label[idx + 1] == 0 { label[idx + 1] = current; stack.append(idx + 1) }
            if y > 0, denoised[idx - work], label[idx - work] == 0 { label[idx - work] = current; stack.append(idx - work) }
            if y < work - 1, denoised[idx + work], label[idx + work] == 0 { label[idx + work] = current; stack.append(idx + work) }
        }
        if count > bestCount { bestCount = count; best = current }
    }
    guard best > 0 else { fail("no subject found in the source image") }

    // Thicken slightly: the blades are thin, and at 18pt a faithful outline
    // renders as a spindly 1px line.
    var solid = [UInt8](repeating: 0, count: n)
    for i in 0..<n { solid[i] = label[i] == best ? 255 : 0 }
    let bold = 3
    var thickened = solid
    for y in 0..<work {
        for x in 0..<work {
            guard solid[y * work + x] == 0 else { continue }
            var hit = false
            for dy in -bold...bold where !hit {
                for dx in -bold...bold where !hit {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= work || ny >= work { continue }
                    if solid[ny * work + nx] == 255 { hit = true }
                }
            }
            if hit { thickened[y * work + x] = 255 }
        }
    }

    // Feather so the mask survives downscaling.
    var alpha = [UInt8](repeating: 0, count: n)
    let radius = 2
    for y in 0..<work {
        for x in 0..<work {
            var sum = 0, count = 0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= work || ny >= work { continue }
                    sum += Int(thickened[ny * work + nx]); count += 1
                }
            }
            alpha[y * work + x] = UInt8(sum / max(1, count))
        }
    }

    var minX = work, minY = work, maxX = -1, maxY = -1
    for y in 0..<work {
        for x in 0..<work where alpha[y * work + x] > 24 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX else { fail("the subject mask came out empty") }

    print("subject: \(bestCount) px, box \(maxX - minX + 1)x\(maxY - minY + 1)")
    return SubjectMask(
        alpha: alpha,
        work: work,
        box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    )
}

/// Renders `image` into a fresh RGBA context so its pixels can be read back.
func rasterise(_ image: CGImage, size: Int) -> Bitmap {
    let ctx = makeContext(width: size, height: size)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let bitmap = Bitmap(ctx) else { fail("context has no backing store") }
    return bitmap
}

/// A black-on-transparent glyph, cropped to the subject.
func silhouette(from image: CGImage, mask: SubjectMask) -> CGImage {
    let box = mask.box
    let width = Int(box.width), height = Int(box.height)
    let out = makeContext(width: width, height: height)
    guard let bmp = Bitmap(out) else { fail("no backing store for the silhouette") }
    for y in 0..<height {
        for x in 0..<width {
            let a = mask.alpha[(y + Int(box.minY)) * mask.work + (x + Int(box.minX))]
            let o = bmp.offset(x, y)
            // premultiplied: black stays black, only alpha matters
            bmp.pixels[o] = 0; bmp.pixels[o + 1] = 0; bmp.pixels[o + 2] = 0
            bmp.pixels[o + 3] = a
        }
    }
    guard let result = out.makeImage() else { fail("cannot produce the silhouette") }
    return result
}

/// The fan in its own colours with the white backdrop knocked out, cropped to
/// the subject. Used for the hero banner.
func cutOutSubject(from image: CGImage, mask: SubjectMask) -> CGImage {
    let work = mask.work
    let source = rasterise(image, size: work)
    let box = mask.box
    let width = Int(box.width), height = Int(box.height)

    let out = makeContext(width: width, height: height)
    guard let bmp = Bitmap(out) else { fail("no backing store for the cut-out") }

    for y in 0..<height {
        for x in 0..<width {
            let sx = x + Int(box.minX), sy = y + Int(box.minY)
            let a = Double(mask.alpha[sy * work + sx]) / 255.0
            let src = source.offset(sx, sy)
            let dst = bmp.offset(x, y)
            // Premultiply against the mask alpha.
            for channel in 0..<3 {
                bmp.pixels[dst + channel] = UInt8((Double(source.pixels[src + channel]) * a).rounded())
            }
            bmp.pixels[dst + 3] = UInt8((a * 255).rounded())
        }
    }
    guard let result = out.makeImage() else { fail("cannot produce the cut-out") }
    return result
}

// MARK: - Banner composition

/// Composes the cut-out fan onto a soft gradient plate.
func banner(subject: CGImage, width: Int, height: Int, top: CGColor, bottom: CGColor) -> CGImage {
    let ctx = makeContext(width: width, height: height)

    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    // The fan sits right of centre and clear of the bottom edge, which is where
    // the panel draws its status chips. The source is close to square while the
    // plate is 3:1, so it is sized by height and given room to breathe.
    let fit = aspectFit(subject, in: CGSize(width: CGFloat(width) * 0.5, height: CGFloat(height) * 0.78))
    let rect = CGRect(
        x: CGFloat(width) * 0.60 - fit.width / 2,
        y: CGFloat(height) * 0.11,
        width: fit.width,
        height: fit.height
    )

    // A soft grounding shadow, so the fan does not look pasted on.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -CGFloat(height) * 0.02),
        blur: CGFloat(height) * 0.09,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
    )
    ctx.draw(subject, in: rect)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fail("cannot compose the banner") }
    return image
}

// MARK: - Build everything

let source = loadSource()
let mask = subjectMask(from: source)
let glyph = silhouette(from: source, mask: mask)
let cutOut = cutOutSubject(from: source, mask: mask)

// Menu bar art is rendered into a 20x18pt box at 1x/2x/3x.
let menuBox = CGSize(width: 20, height: 18)
for scale in [1, 2, 3] {
    let px = CGSize(width: menuBox.width * CGFloat(scale), height: menuBox.height * CGFloat(scale))
    let ctx = makeContext(width: Int(px.width), height: Int(px.height))
    ctx.interpolationQuality = .high
    ctx.draw(glyph, in: aspectFit(glyph, in: px))
    guard let img = ctx.makeImage() else { fail("cannot render the menu bar icon") }
    let name = scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@\(scale)x.png"
    writePNG(img, to: outDir.appendingPathComponent(name))
    print("wrote \(name) at \(Int(px.width))x\(Int(px.height))")
}

// Header chip art.
do {
    let side = 256
    let ctx = makeContext(width: side, height: side)
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let img = ctx.makeImage() else { fail("cannot render the hero art") }
    writePNG(img, to: outDir.appendingPathComponent("FanHero.png"))
    print("wrote FanHero.png at \(side)x\(side)")
}

// Wide hero banners, one per appearance.
do {
    let variants: [(name: String, top: CGColor, bottom: CGColor)] = [
        ("FanBanner.png",
         CGColor(red: 0.97, green: 0.95, blue: 0.92, alpha: 1),
         CGColor(red: 0.86, green: 0.83, blue: 0.78, alpha: 1)),
        ("FanBannerDark.png",
         CGColor(red: 0.17, green: 0.18, blue: 0.21, alpha: 1),
         CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)),
    ]
    for variant in variants {
        let canvas = banner(
            subject: cutOut, width: 900, height: 300,
            top: variant.top, bottom: variant.bottom
        )
        writePNG(canvas, to: outDir.appendingPathComponent(variant.name))
        print("wrote \(variant.name) at 900x300")
    }
}

// MARK: - App icon (macOS squircle)

func drawAppIcon(side: Int) -> CGImage {
    let ctx = makeContext(width: side, height: side)
    let s = CGFloat(side)

    // Apple's icon grid: artwork sits in an 824/1024 rounded square.
    let inset = s * (100.0 / 1024.0)
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // Soft drop shadow behind the plate.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.012),
        blur: s * 0.032,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    )
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Warm cream gradient plate, matching the fan's finish.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1.00, green: 0.99, blue: 0.97, alpha: 1),
            CGColor(red: 0.93, green: 0.90, blue: 0.85, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: plate.maxY),
            end: CGPoint(x: 0, y: plate.minY),
            options: []
        )
    }

    // The cut-out fan, so the plate reads as a background rather than a frame
    // around a white photo.
    let art = plate.insetBy(dx: plate.width * 0.13, dy: plate.width * 0.13)
    let fit = aspectFit(cutOut, in: art.size)
    ctx.draw(cutOut, in: CGRect(
        x: art.minX + fit.minX, y: art.minY + fit.minY,
        width: fit.width, height: fit.height
    ))
    ctx.restoreGState()

    // Hairline edge, like macOS app icons have.
    ctx.addPath(platePath)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.002))
    ctx.strokePath()

    guard let img = ctx.makeImage() else { fail("cannot render the app icon") }
    return img
}

let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconsetDir)
try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let master1024 = drawAppIcon(side: 1024)
for entry in iconSizes {
    let ctx = makeContext(width: entry.px, height: entry.px)
    ctx.interpolationQuality = .high
    ctx.draw(master1024, in: CGRect(x: 0, y: 0, width: entry.px, height: entry.px))
    guard let img = ctx.makeImage() else { fail("cannot render \(entry.name)") }
    writePNG(img, to: iconsetDir.appendingPathComponent("\(entry.name).png"))
}

// MARK: - Debug contact sheet

do {
    let tile = 132
    let width = tile * 5
    let height = tile * 3
    let ctx = makeContext(width: width, height: height)

    for row in 0..<2 {
        let dark = row == 1
        let rowRect = CGRect(x: 0, y: CGFloat(row * tile), width: CGFloat(width), height: CGFloat(tile))
        ctx.setFillColor(dark
            ? CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1))
        ctx.fill(rowRect)

        for (i, factor) in [CGFloat(1), 2, 3, 6].enumerated() {
            let px = CGSize(width: menuBox.width * factor, height: menuBox.height * factor)
            let cell = CGRect(
                x: CGFloat(i * tile) + (CGFloat(tile) - px.width) / 2,
                y: rowRect.minY + (CGFloat(tile) - px.height) / 2,
                width: px.width, height: px.height
            )
            let clean = makeContext(width: Int(px.width), height: Int(px.height))
            clean.interpolationQuality = .high
            clean.draw(glyph, in: aspectFit(glyph, in: px))
            guard let mono = clean.makeImage() else { continue }
            ctx.saveGState()
            ctx.setFillColor(dark
                ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.clip(to: cell, mask: mono)
            ctx.fill(cell)
            ctx.restoreGState()
        }

        let iconSide = tile - 24
        ctx.draw(master1024, in: CGRect(
            x: CGFloat(4 * tile) + 12, y: rowRect.minY + 12,
            width: CGFloat(iconSide), height: CGFloat(iconSide)
        ))
    }

    // Bottom row: the two banners, so the hero art can be checked here too.
    let bannerRect = CGRect(x: 0, y: CGFloat(2 * tile), width: CGFloat(width), height: CGFloat(tile))
    ctx.draw(master1024, in: .zero)   // no-op keeps the context warm
    if let light = CGImageSourceCreateWithURL(
        outDir.appendingPathComponent("FanBanner.png") as CFURL, nil
    ).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        ctx.draw(light, in: CGRect(x: 0, y: bannerRect.minY, width: CGFloat(width) / 2, height: CGFloat(tile)))
    }
    if let dark = CGImageSourceCreateWithURL(
        outDir.appendingPathComponent("FanBannerDark.png") as CFURL, nil
    ).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        ctx.draw(dark, in: CGRect(
            x: CGFloat(width) / 2, y: bannerRect.minY,
            width: CGFloat(width) / 2, height: CGFloat(tile)
        ))
    }

    guard let img = ctx.makeImage() else { fail("cannot render the debug sheet") }
    writePNG(img, to: outDir.appendingPathComponent("_debug-icons.png"))
    print("wrote _debug-icons.png")
}

// MARK: - .icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconsetDir.path,
    "-o", outDir.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
try? fm.removeItem(at: iconsetDir)
print("wrote AppIcon.icns")
print("done")
