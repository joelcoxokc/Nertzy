import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Felt background
let feltColors = [
    CGColor(red: 0.13, green: 0.50, blue: 0.29, alpha: 1),
    CGColor(red: 0.04, green: 0.26, blue: 0.14, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: space, colors: feltColors, locations: [0, 1])!
ctx.drawRadialGradient(
    grad,
    startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512), endRadius: 780,
    options: [.drawsAfterEndLocation]
)

func cardPath(center: CGPoint, w: CGFloat, h: CGFloat, rot: CGFloat) -> CGPath {
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: w * 0.12, cornerHeight: w * 0.12, transform: nil)
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rot)
    return path.copy(using: &t)!
}

func drawCard(center: CGPoint, rot: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(cardPath(center: center, w: 420, h: 596, rot: rot))
    ctx.fillPath()
    ctx.restoreGState()
}

drawCard(center: CGPoint(x: 340, y: 462), rot: 0.30)
drawCard(center: CGPoint(x: 684, y: 462), rot: -0.30)
drawCard(center: CGPoint(x: 512, y: 486), rot: 0)

// Heart: rotated square + two circles on its upper edges
func heartPath(center: CGPoint, a: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k = a / (2 * CGFloat(2).squareRoot())
    var rot = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: .pi / 4)
    p.addRect(CGRect(x: -a / 2, y: -a / 2, width: a, height: a), transform: rot)
    p.addEllipse(in: CGRect(x: center.x - k - a / 2, y: center.y + k - a / 2, width: a, height: a))
    p.addEllipse(in: CGRect(x: center.x + k - a / 2, y: center.y + k - a / 2, width: a, height: a))
    return p
}

ctx.setFillColor(CGColor(red: 0.82, green: 0.16, blue: 0.15, alpha: 1))
ctx.addPath(heartPath(center: CGPoint(x: 512, y: 470), a: 168))
ctx.fillPath()

let img = ctx.makeImage()!
let outPath = FileManager.default.currentDirectoryPath + "/Nertz/Assets.xcassets/AppIcon.appiconset/icon.png"
let url = URL(fileURLWithPath: outPath)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) {
    print("wrote \(outPath)")
} else {
    print("FAILED")
    exit(1)
}
