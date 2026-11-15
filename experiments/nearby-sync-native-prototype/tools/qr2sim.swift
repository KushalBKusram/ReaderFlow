import CoreImage
import Foundation

// usage: qr2sim.swift <qr.png> <simulator-udid>
// Decodes the QR locally and copies its text to the Simulator pasteboard.
// The payload is never printed or written to disk.
let args = CommandLine.arguments
guard args.count == 3,
      let image = CIImage(contentsOf: URL(fileURLWithPath: args[1])),
      let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
      let text = (detector.features(in: image).first as? CIQRCodeFeature)?.messageString
else { FileHandle.standardError.write(Data("could not decode QR\n".utf8)); exit(1) }

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
p.arguments = ["simctl", "pbcopy", args[2]]
let pipe = Pipe(); p.standardInput = pipe
try p.run()
pipe.fileHandleForWriting.write(Data(text.utf8))
try pipe.fileHandleForWriting.close()
p.waitUntilExit()
print("QR payload copied to Simulator pasteboard (\(text.count) chars, not displayed).")
