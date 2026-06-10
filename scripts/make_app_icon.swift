#!/usr/bin/env swift
// Generates the macOS app icon programmatically: the `brain.head.profile` SF
// Symbol filled with the app's purple→blue gradient, centered on a white
// continuous-rounded-rect, rendered at every size the AppIcon set needs.
//
// Run:  swift scripts/make_app_icon.swift
// Writes PNGs + Contents.json into Engram/Engram/Assets.xcassets/AppIcon.appiconset/

import SwiftUI
import AppKit

let appiconset = URL(fileURLWithPath: "Engram/Engram/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

/// One rendered icon tile at a given pixel size.
struct IconView: View {
    let pixel: CGFloat

    var body: some View {
        let inset = pixel * 0.085          // small margin so the squircle isn't full-bleed
        let content = pixel - inset * 2
        let radius = content * 0.2237      // Apple's continuous-corner ratio
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.white)
                .frame(width: content, height: content)
                .shadow(color: .black.opacity(0.16), radius: pixel * 0.018, y: pixel * 0.012)
            Image(systemName: "brain.head.profile")
                .font(.system(size: content * 0.56, weight: .regular))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .frame(width: pixel, height: pixel)
    }
}

@MainActor
func renderPNG(pixel: Int, to url: URL) throws {
    let renderer = ImageRenderer(content: IconView(pixel: CGFloat(pixel)))
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed at \(pixel)px"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixel, height: pixel)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed at \(pixel)px"])
    }
    try data.write(to: url)
}

// (filename, pixel size, size-string, scale) — the ten macOS AppIcon entries.
let entries: [(file: String, pixel: Int, size: String, scale: String)] = [
    ("icon_16x16.png", 16, "16x16", "1x"),
    ("icon_16x16@2x.png", 32, "16x16", "2x"),
    ("icon_32x32.png", 32, "32x32", "1x"),
    ("icon_32x32@2x.png", 64, "32x32", "2x"),
    ("icon_128x128.png", 128, "128x128", "1x"),
    ("icon_128x128@2x.png", 256, "128x128", "2x"),
    ("icon_256x256.png", 256, "256x256", "1x"),
    ("icon_256x256@2x.png", 512, "256x256", "2x"),
    ("icon_512x512.png", 512, "512x512", "1x"),
    ("icon_512x512@2x.png", 1024, "512x512", "2x"),
]

try MainActor.assumeIsolated {
    for entry in entries {
        try renderPNG(pixel: entry.pixel, to: appiconset.appendingPathComponent(entry.file))
        print("rendered \(entry.file) (\(entry.pixel)px)")
    }
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.file)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)",
          "size" : "\(entry.size)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
