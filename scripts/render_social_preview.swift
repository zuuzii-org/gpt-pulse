#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "Usage: render_social_preview.swift <background.png> <icon.png> <output.png>\n"
            .utf8
    ))
    exit(64)
}

let backgroundURL = URL(fileURLWithPath: arguments[1])
let iconURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])

guard let background = NSImage(contentsOf: backgroundURL),
      let icon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write(Data("Unable to load release artwork inputs.\n".utf8))
    exit(66)
}

let canvasSize = NSSize(width: 1_280, height: 640)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Unable to create drawing context.\n".utf8))
    exit(70)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }
context.imageInterpolation = .high

// NSImage reports dimensions in points, which can differ from the backing PNG's
// pixel dimensions. Crop in that coordinate space so the 2:1 canvas is filled
// without clipping the right half of the artwork.
let sourceAspectRatio = background.size.width / background.size.height
let canvasAspectRatio = canvasSize.width / canvasSize.height
let backgroundSourceRect: NSRect
if sourceAspectRatio < canvasAspectRatio {
    let cropHeight = background.size.width / canvasAspectRatio
    backgroundSourceRect = NSRect(
        x: 0,
        y: (background.size.height - cropHeight) / 2,
        width: background.size.width,
        height: cropHeight
    )
} else {
    let cropWidth = background.size.height * canvasAspectRatio
    backgroundSourceRect = NSRect(
        x: (background.size.width - cropWidth) / 2,
        y: 0,
        width: cropWidth,
        height: background.size.height
    )
}

background.draw(
    in: NSRect(origin: .zero, size: canvasSize),
    from: backgroundSourceRect,
    operation: .copy,
    fraction: 1
)
icon.draw(
    in: NSRect(x: 90, y: 130, width: 380, height: 380),
    from: NSRect(origin: .zero, size: icon.size),
    operation: .sourceOver,
    fraction: 1
)

func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: size >= 60 ? -1.2 : 0,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

draw(
    "LLM Pulse",
    at: NSPoint(x: 540, y: 350),
    size: 76,
    weight: .semibold,
    color: .white
)
draw(
    "AI coding tasks, always in sight.",
    at: NSPoint(x: 545, y: 292),
    size: 31,
    weight: .medium,
    color: NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.89, alpha: 1)
)
draw(
    "Native macOS companion by Zuuzii",
    at: NSPoint(x: 545, y: 245),
    size: 23,
    weight: .regular,
    color: NSColor(calibratedRed: 0.50, green: 0.58, blue: 0.68, alpha: 1)
)

context.flushGraphics()
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to encode social preview.\n".utf8))
    exit(74)
}

try pngData.write(to: outputURL, options: .atomic)
