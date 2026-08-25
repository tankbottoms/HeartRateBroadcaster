#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the app icon for both targets: an opaque white field with a single
// red heart. Drawn as a bezier path rather than a "\u{2764}\u{FE0F}" glyph on
// purpose — an emoji rasterised at 1024pt picks up whatever the installed
// Apple Color Emoji font does this year, and iOS rejects icons with alpha,
// which colour-glyph rendering brings along.
//
// Run: swift scripts/make-app-icons.swift

let size = 1024

/// Parametric heart, the standard 16sin³t curve. Sampled densely enough that
/// straight segments are invisible at 1024px.
func heartPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    var points: [CGPoint] = []
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let x = 16 * pow(sin(t), 3)
        let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
        points.append(CGPoint(x: x, y: y))
    }

    // Fit the curve's own bounds (±16, ±17) into the target rect, preserving
    // aspect so the lobes stay round.
    let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
    let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
    let scale = min(rect.width / (maxX - minX), rect.height / (maxY - minY))
    let offsetX = rect.midX - (minX + maxX) / 2 * scale
    let offsetY = rect.midY - (minY + maxY) / 2 * scale

    for (i, p) in points.enumerated() {
        let q = CGPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY)
        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    path.closeSubpath()
    return path
}

func makeIcon() -> Data? {
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        // noneSkipLast: opaque. The App Store and iOS both reject icons that
        // carry an alpha channel.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // 60% of the canvas leaves the margin the system rounded-rect mask expects;
    // any larger and the lobes clip once the corners are rounded.
    let side = CGFloat(size) * 0.60
    let box = CGRect(x: (CGFloat(size) - side) / 2,
                     y: (CGFloat(size) - side) / 2,
                     width: side, height: side)

    context.addPath(heartPath(in: box))
    context.setFillColor(CGColor(red: 0.90, green: 0.13, blue: 0.20, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let targets = [
    "HeartRateBroadcaster/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "HeartRateBroadcasterWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
]

guard let png = makeIcon() else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}

for target in targets {
    let url = URL(fileURLWithPath: target)
    try png.write(to: url)
    print("wrote \(target) (\(png.count) bytes)")
}
