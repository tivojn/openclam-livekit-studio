#!/usr/bin/env swift

import AppKit
import Foundation

/// Rebuild the small monochrome symbol set used by the Electron rail from
/// Apple's native SF Symbols catalogue. The checked-in PNGs are template masks
/// at 4× density, so the web UI keeps the same glyph language as the iPhone app
/// without depending on a network icon font at runtime.
let symbols: [(asset: String, systemName: String)] = [
    ("avatar-picker", "person.2"),
    ("avatar-window", "rectangle.portrait.and.arrow.forward"),
    ("standby", "figure.stand"),
    ("close-up", "person.crop.square"),
    ("horizon-walk", "figure.walk"),
    ("edge-idle", "figure.stand.line.dotted.figure.stand"),
    ("moves", "figure.dance"),
    ("phone", "phone"),
    ("phone-down", "phone.down"),
    ("stop", "stop"),
    ("waveform", "waveform"),
    ("speaker", "speaker.wave.2"),
    ("speaker-slash", "speaker.slash"),
    ("avatar-layer", "person.crop.rectangle"),
    ("thread-layer", "text.bubble"),
    ("opacity", "circle.lefthalf.filled"),
    ("face-mirror", "face.dashed"),
    ("settings", "gearshape"),
    ("chevron-down", "chevron.down"),
    ("checkmark", "checkmark"),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate-sf-symbol-icons.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let canvasPoints: CGFloat = 24
let scale: CGFloat = 4
let pixels = Int(canvasPoints * scale)
let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))

for symbol in symbols {
    guard let source = NSImage(
        systemSymbolName: symbol.systemName,
        accessibilityDescription: nil
    )?.withSymbolConfiguration(baseConfiguration) else {
        fputs("missing SF Symbol: \(symbol.systemName)\n", stderr)
        exit(65)
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("could not create bitmap for \(symbol.systemName)\n", stderr)
        exit(66)
    }

    bitmap.size = NSSize(width: canvasPoints, height: canvasPoints)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("could not create graphics context for \(symbol.systemName)\n", stderr)
        exit(67)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: canvasPoints, height: canvasPoints).fill()

    let sourceSize = source.size
    let maximumSide: CGFloat = 20
    let fitScale = min(maximumSide / max(sourceSize.width, 1), maximumSide / max(sourceSize.height, 1))
    let drawSize = NSSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
    let drawRect = NSRect(
        x: (canvasPoints - drawSize.width) / 2,
        y: (canvasPoints - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("could not encode \(symbol.systemName)\n", stderr)
        exit(68)
    }
    try png.write(to: outputDirectory.appendingPathComponent("\(symbol.asset).png"))
}

print("generated \(symbols.count) SF Symbol masks in \(outputDirectory.path)")
