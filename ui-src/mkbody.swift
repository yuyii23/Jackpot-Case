// Body-only mask for the closed-lid look: the existing feathered cut-out
// (case-mask.png) kept only below the case rim, plus the strap column on the
// right, so the open lid and the pods above the rim drop away.
//   swiftc -O mkbody.swift -o /tmp/mkbody && /tmp/mkbody case-mask.png body-mask.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let W = src.width, H = src.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgba(_ img: CGImage?) -> [UInt8] {
  var buf = [UInt8](repeating: 0, count: W * H * 4)
  let c = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  if let img { c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H)) }
  return buf
}
let mask = rgba(src)

// region, in image coordinates (top-left origin), at 540 x 517
let rim = 163.0, rimSoft = 7.0           // fade just above the rim line
let strapX = 352.0, strapTop = 116.0, strapSoft = 8.0
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
  let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}
var out = [UInt8](repeating: 0, count: W * H * 4)
for y in 0..<H {
  for x in 0..<W {
    let fy = Double(y), fx = Double(x)
    let below = smooth(rim - rimSoft, rim, fy)
    let strap = smooth(strapX - strapSoft, strapX, fx) * smooth(strapTop - strapSoft, strapTop, fy)
    let region = max(below, strap)
    let i = (y * W + x) * 4
    let alpha = Double(mask[i + 3]) / 255 * region
    let v = UInt8((alpha * 255).rounded())
    out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = v     // premultiplied white
  }
}
let ctx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
print("wrote \(a[2]) \(W)x\(H)")
