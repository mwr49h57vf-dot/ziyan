import CoreGraphics
import Foundation
import ImageIO
import Vision

private func normalized(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
    }
    return String(String.UnicodeScalarView(scalars))
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: zy_toast_visual_gate <image> <expected-text>\n", stderr)
    exit(2)
}

let imagePath = CommandLine.arguments[1]
let expectedRaw = CommandLine.arguments[2]
let expectedValues = expectedRaw.split(separator: "|", omittingEmptySubsequences: true)
    .map { normalized(String($0)) }
    .filter { !$0.isEmpty }
guard !expectedValues.isEmpty else {
    fputs("ERROR=empty_expected_text\n", stderr)
    exit(2)
}

let imageURL = URL(fileURLWithPath: imagePath) as CFURL
guard let source = CGImageSourceCreateWithURL(imageURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("VISUAL_VERDICT=FAIL")
    print("VISUAL_REASON=decode")
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.minimumTextHeight = 0.015

do {
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up,
                                        options: [:])
    try handler.perform([request])
} catch {
    print("VISUAL_VERDICT=FAIL")
    print("VISUAL_REASON=vision_error")
    exit(1)
}

struct Candidate {
    let text: String
    let normalized: String
    let box: CGRect
}

let observations = request.results ?? []
var candidates: [Candidate] = []
for observation in observations {
    guard let top = observation.topCandidates(3).first else { continue }
    candidates.append(Candidate(text: top.string,
                                normalized: normalized(top.string),
                                box: observation.boundingBox))
}

for candidate in candidates {
    let topOriginMidY = 1.0 - candidate.box.midY
    print(String(format:
        "OCR text=%@ norm=%@ x=%.4f y_top=%.4f w=%.4f h=%.4f",
        candidate.text, candidate.normalized, candidate.box.midX,
        topOriginMidY, candidate.box.width, candidate.box.height))
}

var matched: Candidate?
for candidate in candidates {
    if expectedValues.contains(where: {
        candidate.normalized == $0 || candidate.normalized.contains($0)
    }) {
        matched = candidate
        break
    }
}

if matched == nil {
    let lowerBand = candidates
        .filter { (1.0 - $0.box.midY) >= 0.65 }
        .sorted { $0.box.minX < $1.box.minX }
    for start in lowerBand.indices {
        var combined = ""
        var union = CGRect.null
        for end in start..<lowerBand.count {
            combined += lowerBand[end].normalized
            union = union.union(lowerBand[end].box)
            if expectedValues.contains(where: {
                combined == $0 || combined.contains($0)
            }) {
                matched = Candidate(text: combined, normalized: combined,
                                    box: union)
                break
            }
            let longestExpected = expectedValues.map(\.count).max() ?? 1
            if combined.count > longestExpected * 2 { break }
        }
        if matched != nil { break }
    }
}

guard let hit = matched else {
    print("EXPECTED_TEXT=\(expectedRaw)")
    print("VISUAL_VERDICT=FAIL")
    print("VISUAL_REASON=text_missing")
    exit(1)
}

let x = hit.box.midX
let yTop = 1.0 - hit.box.midY
let positionOK = x >= 0.35 && x <= 0.65 && yTop >= 0.70 && yTop <= 0.98
print("EXPECTED_TEXT=\(expectedRaw)")
print(String(format: "MATCH_X=%.4f", x))
print(String(format: "MATCH_Y_TOP=%.4f", yTop))
print("POSITION_OK=\(positionOK ? 1 : 0)")
print("IMAGE_WIDTH=\(image.width)")
print("IMAGE_HEIGHT=\(image.height)")
print("VISUAL_VERDICT=\(positionOK ? "PASS" : "FAIL")")
print("VISUAL_REASON=\(positionOK ? "ok" : "position")")
exit(positionOK ? 0 : 1)
