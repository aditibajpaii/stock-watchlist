// Print the text that macOS Vision recognises in one or more images.
//
//   swiftc -O scripts/review2_ocr.swift -o <dir>/review2_ocr && <dir>/review2_ocr image.png ...
//
// Output: for every image a line "== <path> <width>x<height>", then one line
// per recognised text line: "<top y in pixels>\t<left x in pixels>\t<text>",
// sorted from top to bottom. Used by scripts/review2_evidence.py (screenshot
// checks) to confirm that a screenshot shows the expected SQL and output.
// It only reads the images; nothing is sent anywhere.

import AppKit
import Foundation
import Vision

func recognise(_ path: String) -> Int32 {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("== \(path) UNREADABLE")
        return 1
    }
    let width = Double(cg.width), height = Double(cg.height)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0
    do {
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    } catch {
        print("== \(path) FAILED \(error)")
        return 1
    }
    var lines: [(Int, Int, String)] = []
    for obs in request.results ?? [] {
        guard let best = obs.topCandidates(1).first else { continue }
        let box = obs.boundingBox  // normalised, origin bottom-left
        let top = Int(((1.0 - box.maxY) * height).rounded())
        let left = Int((box.minX * width).rounded())
        lines.append((top, left, best.string))
    }
    lines.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    print("== \(path) \(cg.width)x\(cg.height)")
    for (top, left, text) in lines {
        print("\(top)\t\(left)\t\(text)")
    }
    return 0
}

var status: Int32 = 0
for path in CommandLine.arguments.dropFirst() {
    status |= recognise(path)
}
exit(status)
