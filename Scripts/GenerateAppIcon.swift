import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconGenerationError: Error { case context, image, destination, write }

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
    bytesPerRow: side * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw IconGenerationError.context
}

context.setFillColor(CGColor(red: 0.12, green: 0.38, blue: 0.62, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))

let bubble = CGPath(roundedRect: CGRect(x: 154, y: 286, width: 716, height: 452),
    cornerWidth: 116, cornerHeight: 116, transform: nil)
context.addPath(bubble)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()

let tail = CGMutablePath()
tail.move(to: CGPoint(x: 274, y: 322))
tail.addLine(to: CGPoint(x: 154, y: 176))
tail.addLine(to: CGPoint(x: 396, y: 322))
tail.closeSubpath()
context.addPath(tail)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()

context.setStrokeColor(CGColor(red: 0.12, green: 0.38, blue: 0.62, alpha: 1))
context.setLineWidth(34)
context.setLineCap(.round)
for (x, height) in [(322.0, 86.0), (438, 154), (554, 108), (670, 186), (786, 94)] {
    context.move(to: CGPoint(x: x, y: 512 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 512 + height / 2))
    context.strokePath()
}

guard let image = context.makeImage() else { throw IconGenerationError.image }
let output = CommandLine.arguments.dropFirst().first ?? "SayAgainApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let outputURL = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    throw IconGenerationError.destination
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { throw IconGenerationError.write }
