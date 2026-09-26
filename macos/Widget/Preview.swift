// Renders the widget view offscreen to PNGs (light + dark, small + medium) so
// the design can be checked without a screenshot or a screen-recording
// permission.
//
// Build/run: ./render-widget-preview.sh

import AppKit
import SwiftUI

@main
struct WidgetPreview {
    @MainActor
    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

        let sample: [DeviceReading] = [
            DeviceReading(id: "mac", name: "Mac", kind: "mac", level: 100, charging: false),
            DeviceReading(id: "acc", name: "OPPO Enco Free4", kind: "headphones", level: 80, charging: false),
            DeviceReading(id: "phone", name: "phone", kind: "phone", level: 64, charging: true),
        ]

        let medium = CGSize(width: 364, height: 170)
        let small = CGSize(width: 170, height: 170)

        render(WidgetContent(devices: sample, compact: false), size: medium,
               scheme: .dark, to: "\(outputDirectory)/widget-medium-dark.png")
        render(WidgetContent(devices: sample, compact: false), size: medium,
               scheme: .light, to: "\(outputDirectory)/widget-medium-light.png")
        render(WidgetContent(devices: sample, compact: true), size: small,
               scheme: .dark, to: "\(outputDirectory)/widget-small-dark.png")
        render(WidgetContent(devices: sample, compact: true), size: small,
               scheme: .light, to: "\(outputDirectory)/widget-small-light.png")
    }

    @MainActor
    private static func render(_ content: some View, size: CGSize, scheme: ColorScheme, to path: String) {
        let card = ZStack {
            WidgetBackground()
            content
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed for \(path)\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
