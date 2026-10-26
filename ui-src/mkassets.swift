// Same cut-out as mkcase, but split into a small JPEG (colour) and an alpha PNG
// (feathered mask) so the page can inline both without a half-megabyte PNG.
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), outJPG = URL(fileURLWithPath: a[2]), outMask = URL(fileURLWithPath: a[3])
let scale: CGFloat = 540.0 / 610.0
let isrc = CGImageSourceCreateWithURL(src as CFURL, nil)!
let full = CGImageSourceCreateImageAtIndex(isrc, 0, nil)!
let crop = CGRect(x: 250, y: 515, width: 610, height: 585)
let cropped = full.cropping(to: crop)!
let W = Int(crop.width * scale), H = Int(crop.height * scale)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// colour: scaled JPEG
let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.interpolationQuality = .high
c.draw(cropped, in: CGRect(x: 0, y: 0, width: W, height: H))
let jpg = CGImageDestinationCreateWithURL(outJPG as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(jpg, c.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
CGImageDestinationFinalize(jpg)

// mask: white rounded rect minus the bubble, blurred, written as alpha
let m = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
m.setFillColor(CGColor(gray: 0, alpha: 1)); m.fill(CGRect(x: 0, y: 0, width: W, height: H))
m.setFillColor(CGColor(gray: 1, alpha: 1))
m.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: 30, dy: 30),
                 cornerWidth: 130, cornerHeight: 130, transform: nil)); m.fillPath()
m.setFillColor(CGColor(gray: 0, alpha: 1))
let bx = 540 * scale, by = CGFloat(H) - 33 * scale, br = 118 * scale
m.fillEllipse(in: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
let ci = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])
let blurred = CIImage(cgImage: m.makeImage()!).clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
    .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
// luminance -> alpha: CIMaskToAlpha
let alpha = blurred.applyingFilter("CIMaskToAlpha")
let maskImg = ci.createCGImage(alpha, from: alpha.extent, format: .RGBA8, colorSpace: cs)!
let png = CGImageDestinationCreateWithURL(outMask as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, maskImg, nil)
CGImageDestinationFinalize(png)
print("wrote \(W)x\(H)")
