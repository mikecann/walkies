// Lifts a sticker off its background with Vision (like long-pressing a photo),
// trims it and saves a square transparent PNG.
// Usage: swift scripts/cutout.swift in.png out.png [size]
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
let size = args.count > 3 ? Double(args[3])! : 512
guard let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Can't read \(args[1])")
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: source)
try handler.perform([request])
guard let result = request.results?.first else { fatalError("No sticker found in \(args[1])") }
let masked = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)

let lifted = CIImage(cvPixelBuffer: masked)
let side = max(lifted.extent.width, lifted.extent.height) * 1.06
let scale = size / side
let centred = lifted
    .transformed(by: CGAffineTransform(translationX: -lifted.extent.minX + (side - lifted.extent.width) / 2,
                                       y: -lifted.extent.minY + (side - lifted.extent.height) / 2))
    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let context = CIContext()
let output = context.createCGImage(centred, from: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
let rep = NSBitmapImageRep(cgImage: output)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")
