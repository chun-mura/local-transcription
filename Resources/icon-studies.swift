import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum IconStudies {
    static func main() {
        run()
    }
}

private let canvas = 1024
private let paper = CGColor(red: 0.102, green: 0.102, blue: 0.110, alpha: 1)
private let ink = CGColor(red: 0.910, green: 0.905, blue: 0.890, alpha: 1)
private let other = CGColor(red: 0.730, green: 0.750, blue: 0.780, alpha: 1)
private let seal = CGColor(red: 0.890, green: 0.230, blue: 0.200, alpha: 1)

private func run() {
    let dir = URL(fileURLWithPath: "Resources/icon-studies", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    write(stroke(), to: dir.appendingPathComponent("01-stroke.png"))
    write(chop(), to: dir.appendingPathComponent("02-chop.png"))
    write(twoLines(), to: dir.appendingPathComponent("03-lines.png"))
    write(arc(), to: dir.appendingPathComponent("04-arc.png"))
}

private func canvasContext() -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: canvas,
        height: canvas,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("キャンバスを作れませんでした\n", stderr)
        exit(1)
    }
    context.setFillColor(paper)
    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    return context
}

private func image(from context: CGContext) -> CGImage {
    guard let image = context.makeImage() else {
        fputs("画像を作れませんでした\n", stderr)
        exit(1)
    }
    return image
}

private func stroke() -> CGImage {
    let context = canvasContext()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 168, y: 548))
    path.addCurve(to: CGPoint(x: 430, y: 690), control1: CGPoint(x: 230, y: 620), control2: CGPoint(x: 320, y: 700))
    path.addCurve(to: CGPoint(x: 860, y: 536), control1: CGPoint(x: 620, y: 672), control2: CGPoint(x: 760, y: 590))
    path.addCurve(to: CGPoint(x: 700, y: 470), control1: CGPoint(x: 820, y: 512), control2: CGPoint(x: 760, y: 488))
    path.addCurve(to: CGPoint(x: 390, y: 430), control1: CGPoint(x: 600, y: 440), control2: CGPoint(x: 500, y: 400))
    path.addCurve(to: CGPoint(x: 168, y: 548), control1: CGPoint(x: 250, y: 468), control2: CGPoint(x: 180, y: 490))
    context.setFillColor(seal)
    context.addPath(path)
    context.fillPath()
    return image(from: context)
}

private func chop() -> CGImage {
    let context = canvasContext()
    let mark = CGRect(x: 548, y: 176, width: 300, height: 300)
    context.setFillColor(seal)
    context.fill(mark)
    context.setFillColor(paper)
    context.fill(mark.insetBy(dx: 46, dy: 46))
    return image(from: context)
}

private func twoLines() -> CGImage {
    let context = canvasContext()
    context.setFillColor(other)
    context.fill(CGRect(x: 176, y: 560, width: 672, height: 44))
    context.setFillColor(ink)
    context.fill(CGRect(x: 176, y: 420, width: 468, height: 44))
    context.setFillColor(seal)
    context.fill(CGRect(x: 176, y: 420, width: 44, height: 184))
    return image(from: context)
}

private func arc() -> CGImage {
    let context = canvasContext()
    context.setStrokeColor(seal)
    context.setLineWidth(78)
    context.setLineCap(.butt)
    context.addArc(
        center: CGPoint(x: 512, y: 512),
        radius: 250,
        startAngle: .pi * 0.72,
        endAngle: .pi * 2.18,
        clockwise: false
    )
    context.strokePath()
    return image(from: context)
}

private func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("書き出し先を作れませんでした\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("書き出せませんでした\n", stderr)
        exit(1)
    }
}
