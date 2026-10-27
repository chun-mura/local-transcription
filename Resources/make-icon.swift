import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum MakeIcon {
    static func main() {
        run()
    }
}

private func run() {
    let size = 1024
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("キャンバスを作れませんでした\n", stderr)
        exit(1)
    }

    context.setFillColor(CGColor(red: 0.102, green: 0.102, blue: 0.110, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))

    let mark = makeMark()
    let bounds = mark.bounds
    let limit: CGFloat = 800
    let scale = min(limit / bounds.width, limit / bounds.height)

    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.midX, y: -bounds.midY)
    context.setFillColor(CGColor(red: 0.890, green: 0.230, blue: 0.200, alpha: 1))
    for wave in mark.waves {
        context.addPath(wave)
    }
    context.fillPath()
    context.fillEllipse(in: mark.dot)
    context.restoreGState()

    guard let image = context.makeImage() else {
        fputs("画像を作れませんでした\n", stderr)
        exit(1)
    }
    let url = URL(fileURLWithPath: "Resources/AppIcon.png") as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fputs("書き出し先を作れませんでした\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("書き出せませんでした\n", stderr)
        exit(1)
    }
}

private struct Mark {
    var waves: [CGPath]
    var dot: CGRect
    var bounds: CGRect
}

private func makeMark() -> Mark {
    let along = CGPoint(x: 0.7071, y: -0.7071)
    let across = CGPoint(x: 0.7071, y: 0.7071)
    let waves: [(mid: CGPoint, half: CGFloat, bulge: CGFloat, width: CGFloat)] = [
        (CGPoint(x: 250, y: 760), 188, 72, 40),
        (CGPoint(x: 378, y: 632), 142, 54, 62),
        (CGPoint(x: 496, y: 514), 96, 36, 88),
    ]

    var paths: [CGPath] = []
    var bounds = CGRect.null
    for wave in waves {
        let start = CGPoint(
            x: wave.mid.x - across.x * wave.half,
            y: wave.mid.y - across.y * wave.half
        )
        let end = CGPoint(
            x: wave.mid.x + across.x * wave.half,
            y: wave.mid.y + across.y * wave.half
        )
        let control = CGPoint(
            x: wave.mid.x + along.x * wave.bulge,
            y: wave.mid.y + along.y * wave.bulge
        )
        let path = ribbon(from: start, to: end, control: control, width: wave.width)
        paths.append(path)
        bounds = bounds.union(path.boundingBox)
    }

    let dotRadius: CGFloat = 84
    let dotCenter = CGPoint(x: 668, y: 352)
    let dot = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    bounds = bounds.union(dot)
    return Mark(waves: paths, dot: dot, bounds: bounds)
}

private func ribbon(from start: CGPoint, to end: CGPoint, control: CGPoint, width: CGFloat) -> CGPath {
    let samples = 48
    var centers: [CGPoint] = []
    var widths: [CGFloat] = []
    for index in 0...samples {
        let t = CGFloat(index) / CGFloat(samples)
        let u = 1 - t
        centers.append(CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        ))
        let taper = sin(.pi * t)
        widths.append(width * (0.72 + 0.28 * taper))
    }
    return ribbonPath(centers: centers, widths: widths)
}

private func ribbonPath(centers: [CGPoint], widths: [CGFloat]) -> CGPath {
    let count = centers.count
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    var tangents: [(CGFloat, CGFloat)] = []
    var normals: [(CGFloat, CGFloat)] = []

    for index in 0..<count {
        let before = centers[max(0, index - 1)]
        let after = centers[min(count - 1, index + 1)]
        var tangentX = after.x - before.x
        var tangentY = after.y - before.y
        let length = max(0.001, hypot(tangentX, tangentY))
        tangentX /= length
        tangentY /= length
        tangents.append((tangentX, tangentY))
        normals.append((-tangentY, tangentX))
        let half = widths[index] / 2
        left.append(CGPoint(x: centers[index].x + normals[index].0 * half, y: centers[index].y + normals[index].1 * half))
        right.append(CGPoint(x: centers[index].x - normals[index].0 * half, y: centers[index].y - normals[index].1 * half))
    }

    let path = CGMutablePath()
    path.move(to: left[0])
    for vertex in left.dropFirst() { path.addLine(to: vertex) }
    appendCap(to: path, center: centers[count - 1], normal: normals[count - 1], tangent: tangents[count - 1], radius: widths[count - 1] / 2, forward: true)
    for vertex in right.reversed() { path.addLine(to: vertex) }
    appendCap(to: path, center: centers[0], normal: normals[0], tangent: tangents[0], radius: widths[0] / 2, forward: false)
    path.closeSubpath()
    return path
}

private func appendCap(
    to path: CGMutablePath,
    center: CGPoint,
    normal: (CGFloat, CGFloat),
    tangent: (CGFloat, CGFloat),
    radius: CGFloat,
    forward: Bool
) {
    for step in 1...10 {
        let angle = CGFloat(step) / 10 * .pi
        let normalScale = cos(angle) * (forward ? 1 : -1)
        let tangentScale = sin(angle) * (forward ? 1 : -1)
        path.addLine(to: CGPoint(
            x: center.x + (normal.0 * normalScale + tangent.0 * tangentScale) * radius,
            y: center.y + (normal.1 * normalScale + tangent.1 * tangentScale) * radius
        ))
    }
}
