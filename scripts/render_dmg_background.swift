#!/usr/bin/env swift

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

private let canvasSize = CGSize(width: 640, height: 420)

private struct RenderTarget {
    let scale: Int
    let artworkName: String
    let outputName: String
}

private enum RenderError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case unreadableImage(URL)
    case unexpectedDimensions(URL, expected: CGSize, actual: CGSize)
    case contextCreationFailed
    case imageCreationFailed
    case imageWriteFailed(URL)

    var description: String {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .unreadableImage(url):
            return "Cannot read image: \(url.path)"
        case let .unexpectedDimensions(url, expected, actual):
            return "Unexpected dimensions for \(url.lastPathComponent): "
                + "\(Int(actual.width))x\(Int(actual.height)); expected "
                + "\(Int(expected.width))x\(Int(expected.height))"
        case .contextCreationFailed:
            return "Cannot create the bitmap rendering context"
        case .imageCreationFailed:
            return "Cannot create the rendered image"
        case let .imageWriteFailed(url):
            return "Cannot write image: \(url.path)"
        }
    }
}

private func color(
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    alpha: CGFloat = 1
) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [red, green, blue, alpha]
    )!
}

private let white = color(red: 1, green: 1, blue: 1)
private let electricBlue = color(red: 0.08, green: 0.58, blue: 1)
private let iceBlue = color(red: 0.52, green: 0.84, blue: 1)

private func topAlignedRect(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) -> CGRect {
    CGRect(
        x: x,
        y: canvasSize.height - y - height,
        width: width,
        height: height
    )
}

private func loadImage(at url: URL) throws -> CGImage {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw RenderError.unreadableImage(url)
    }
    return image
}

private func makeContext(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw RenderError.contextCreationFailed
    }
    context.interpolationQuality = .high
    return context
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw RenderError.imageWriteFailed(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderError.imageWriteFailed(url)
    }
}

private func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

private func drawGradient(
    in context: CGContext,
    path: CGPath,
    colors: [CGColor],
    from start: CGPoint,
    to end: CGPoint
) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: nil
    ) else {
        return
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

private func drawCard(
    in context: CGContext,
    x: CGFloat,
    accent: Bool
) {
    let rect = topAlignedRect(x: x, y: 112, width: 156, height: 190)
    let path = roundedPath(rect, radius: 24)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -8),
        blur: 24,
        color: color(red: 0, green: 0, blue: 0, alpha: 0.42)
    )
    context.addPath(path)
    context.setFillColor(color(red: 0.025, green: 0.045, blue: 0.075, alpha: 0.74))
    context.fillPath()
    context.restoreGState()

    drawGradient(
        in: context,
        path: path,
        colors: accent
            ? [
                color(red: 0.08, green: 0.33, blue: 0.60, alpha: 0.19),
                color(red: 0.025, green: 0.075, blue: 0.13, alpha: 0.62),
            ]
            : [
                color(red: 0.30, green: 0.38, blue: 0.49, alpha: 0.13),
                color(red: 0.025, green: 0.055, blue: 0.09, alpha: 0.58),
            ],
        from: CGPoint(x: rect.midX, y: rect.maxY),
        to: CGPoint(x: rect.midX, y: rect.minY)
    )

    context.saveGState()
    if accent {
        context.setShadow(
            offset: .zero,
            blur: 12,
            color: color(red: 0.05, green: 0.55, blue: 1, alpha: 0.36)
        )
    }
    context.addPath(path)
    context.setStrokeColor(
        accent
            ? color(red: 0.23, green: 0.68, blue: 1, alpha: 0.58)
            : color(red: 0.72, green: 0.82, blue: 0.96, alpha: 0.20)
    )
    context.setLineWidth(accent ? 1.25 : 1)
    context.strokePath()
    context.restoreGState()
}

private func drawLabelPlate(
    in context: CGContext,
    x: CGFloat,
    accent: Bool
) {
    // Finder renders unselected labels in black on custom image backgrounds.
    // This deliberately light plate sits exactly beneath that native label.
    let rect = topAlignedRect(x: x, y: 260, width: 120, height: 36)
    let path = roundedPath(rect, radius: 11)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -3),
        blur: 10,
        color: color(red: 0, green: 0, blue: 0, alpha: 0.42)
    )
    context.addPath(path)
    context.setFillColor(color(red: 0.88, green: 0.92, blue: 0.97, alpha: 0.94))
    context.fillPath()
    context.restoreGState()

    drawGradient(
        in: context,
        path: path,
        colors: accent
            ? [
                color(red: 0.94, green: 0.98, blue: 1, alpha: 0.98),
                color(red: 0.66, green: 0.83, blue: 0.95, alpha: 0.96),
            ]
            : [
                color(red: 0.96, green: 0.97, blue: 0.99, alpha: 0.98),
                color(red: 0.74, green: 0.79, blue: 0.86, alpha: 0.96),
            ],
        from: CGPoint(x: rect.midX, y: rect.maxY),
        to: CGPoint(x: rect.midX, y: rect.minY)
    )

    context.addPath(path)
    context.setStrokeColor(
        accent
            ? color(red: 0.55, green: 0.86, blue: 1, alpha: 0.82)
            : color(red: 1, green: 1, blue: 1, alpha: 0.55)
    )
    context.setLineWidth(1)
    context.strokePath()
}

private func drawCenteredText(
    _ text: String,
    in context: CGContext,
    top: CGFloat,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    color textColor: CGColor,
    tracking: CGFloat = 0,
    shadow: Bool = false
) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight) as CTFont
    let attributes: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: textColor,
        kCTKernAttributeName as NSAttributedString.Key: tracking,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
    let x = (canvasSize.width - width) / 2
    let baseline = canvasSize.height - top - bounds.maxY

    context.saveGState()
    if shadow {
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 9,
            color: color(red: 0, green: 0.28, blue: 0.65, alpha: 0.72)
        )
    }
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
}

private func drawInstallArrow(in context: CGContext) {
    let start = CGPoint(x: 252, y: canvasSize.height - 205)
    let lineEnd = CGPoint(x: 386, y: start.y)
    let tip = CGPoint(x: 402, y: start.y)

    let line = CGMutablePath()
    line.move(to: start)
    line.addCurve(
        to: lineEnd,
        control1: CGPoint(x: 292, y: start.y + 2),
        control2: CGPoint(x: 346, y: start.y + 2)
    )

    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: 15,
        color: color(red: 0.02, green: 0.52, blue: 1, alpha: 0.92)
    )
    context.addPath(line)
    context.setStrokeColor(color(red: 0.08, green: 0.52, blue: 1, alpha: 0.30))
    context.setLineCap(.round)
    context.setLineWidth(9)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(line)
    context.replacePathWithStrokedPath()
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [electricBlue, iceBlue] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: start,
            end: lineEnd,
            options: []
        )
    }
    context.restoreGState()

    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: 12,
        color: color(red: 0.05, green: 0.58, blue: 1, alpha: 0.92)
    )
    let arrowHead = CGMutablePath()
    arrowHead.move(to: tip)
    arrowHead.addLine(to: CGPoint(x: 383, y: start.y + 12))
    arrowHead.addLine(to: CGPoint(x: 389, y: start.y))
    arrowHead.addLine(to: CGPoint(x: 383, y: start.y - 12))
    arrowHead.closeSubpath()
    context.addPath(arrowHead)
    context.setFillColor(iceBlue)
    context.fillPath()
    context.restoreGState()

    context.setFillColor(white)
    context.fillEllipse(in: CGRect(x: start.x - 2.25, y: start.y - 2.25, width: 4.5, height: 4.5))

    for (offset, alpha) in [(-14.0, 0.70), (-24.0, 0.42), (-33.0, 0.22)] {
        let size: CGFloat = offset == -14 ? 3 : 2
        context.setFillColor(color(red: 0.20, green: 0.66, blue: 1, alpha: alpha))
        context.fillEllipse(
            in: CGRect(
                x: start.x + offset - size / 2,
                y: start.y - size / 2,
                width: size,
                height: size
            )
        )
    }
}

private func drawOverlay(in context: CGContext) {
    drawCenteredText(
        "Drag to install",
        in: context,
        top: 44,
        fontSize: 20,
        weight: .semibold,
        color: color(red: 0.94, green: 0.97, blue: 1, alpha: 0.98),
        tracking: -0.15,
        shadow: true
    )
    drawCenteredText(
        "拖到 Applications 完成安装",
        in: context,
        top: 72,
        fontSize: 11,
        weight: .medium,
        color: color(red: 0.57, green: 0.75, blue: 0.91, alpha: 0.92),
        tracking: 0.08
    )

    drawCard(in: context, x: 82, accent: false)
    drawCard(in: context, x: 402, accent: true)
    drawInstallArrow(in: context)

    drawLabelPlate(in: context, x: 100, accent: false)
    drawLabelPlate(in: context, x: 420, accent: true)
}

private func renderBackground(
    target: RenderTarget,
    assetsDirectory: URL
) throws -> URL {
    let inputURL = assetsDirectory.appendingPathComponent(target.artworkName)
    let outputURL = assetsDirectory.appendingPathComponent(target.outputName)
    let input = try loadImage(at: inputURL)
    let expected = CGSize(
        width: canvasSize.width * CGFloat(target.scale),
        height: canvasSize.height * CGFloat(target.scale)
    )
    let actual = CGSize(width: input.width, height: input.height)
    guard actual == expected else {
        throw RenderError.unexpectedDimensions(inputURL, expected: expected, actual: actual)
    }

    let context = try makeContext(width: input.width, height: input.height)
    context.draw(
        input,
        in: CGRect(x: 0, y: 0, width: input.width, height: input.height)
    )
    context.saveGState()
    context.scaleBy(x: CGFloat(target.scale), y: CGFloat(target.scale))
    drawOverlay(in: context)
    context.restoreGState()

    guard let output = context.makeImage() else {
        throw RenderError.imageCreationFailed
    }
    try writePNG(output, to: outputURL)
    return outputURL
}

private func drawPreviewLabel(
    _ text: String,
    centerX: CGFloat,
    in context: CGContext
) {
    let font = NSFont.systemFont(ofSize: 14, weight: .regular) as CTFont
    let attributes: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key:
            color(red: 0.04, green: 0.055, blue: 0.075),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textPosition = CGPoint(
        x: centerX - width / 2,
        y: canvasSize.height - 283
    )
    CTLineDraw(line, context)
}

private func cgImage(from image: NSImage) -> CGImage? {
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

private func renderPreview(
    backgroundURL: URL,
    appIconURL: URL,
    outputURL: URL
) throws {
    let background = try loadImage(at: backgroundURL)
    let context = try makeContext(width: background.width, height: background.height)
    context.draw(
        background,
        in: CGRect(x: 0, y: 0, width: background.width, height: background.height)
    )
    context.saveGState()
    context.scaleBy(x: 2, y: 2)

    if let appIcon = NSImage(contentsOf: appIconURL).flatMap(cgImage) {
        context.draw(
            appIcon,
            in: topAlignedRect(x: 105, y: 150, width: 110, height: 110)
        )
    }
    if let applicationsIcon = cgImage(from: NSWorkspace.shared.icon(forFile: "/Applications")) {
        context.draw(
            applicationsIcon,
            in: topAlignedRect(x: 425, y: 150, width: 110, height: 110)
        )
    }

    context.textMatrix = .identity
    drawPreviewLabel("LLM Pulse", centerX: 160, in: context)
    drawPreviewLabel("Applications", centerX: 480, in: context)
    context.restoreGState()

    guard let preview = context.makeImage() else {
        throw RenderError.imageCreationFailed
    }
    try writePNG(preview, to: outputURL)
}

private func main() throws {
    var previewPath: String?
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--preview":
            guard !arguments.isEmpty else {
                throw RenderError.invalidArguments("--preview requires an output path")
            }
            previewPath = arguments.removeFirst()
        case "-h", "--help":
            print("Usage: scripts/render_dmg_background.swift [--preview PATH]")
            return
        default:
            throw RenderError.invalidArguments("Unknown argument: \(argument)")
        }
    }

    let scriptsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = scriptsDirectory.deletingLastPathComponent()
    let assetsDirectory = repoRoot
        .appendingPathComponent("Assets", isDirectory: true)
        .appendingPathComponent("Release", isDirectory: true)

    let targets = [
        RenderTarget(
            scale: 1,
            artworkName: "dmg-background-artwork.png",
            outputName: "dmg-background.png"
        ),
        RenderTarget(
            scale: 2,
            artworkName: "dmg-background-artwork@2x.png",
            outputName: "dmg-background@2x.png"
        ),
    ]

    for target in targets {
        let output = try renderBackground(target: target, assetsDirectory: assetsDirectory)
        print("Rendered \(target.scale)x DMG background: \(output.path)")
    }

    if let previewPath {
        let previewURL = URL(fileURLWithPath: previewPath, relativeTo: repoRoot)
            .standardizedFileURL
        try renderPreview(
            backgroundURL: assetsDirectory.appendingPathComponent("dmg-background@2x.png"),
            appIconURL: repoRoot
                .appendingPathComponent("Assets/Brand/GPTPulse-AppIcon-Rendered-512.png"),
            outputURL: previewURL
        )
        print("Rendered Finder preview: \(previewURL.path)")
    }
}

do {
    try main()
} catch {
    fputs("render_dmg_background: \(error)\n", stderr)
    exit(1)
}
