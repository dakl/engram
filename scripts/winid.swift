// Print the CGWindowID of the largest on-screen, normal-layer window owned by the
// given app (default "Engram"). Owner name + number are available without Screen
// Recording permission; used by screenshot.sh to capture a window by id.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Engram"
let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
let infoList: [[String: Any]] = (raw as? [[String: Any]]) ?? []

var bestNumber = -1
var bestArea: CGFloat = -1
for window in infoList {
    let ownerName = window[kCGWindowOwnerName as String] as? String
    let layer = window[kCGWindowLayer as String] as? Int
    guard ownerName == owner, layer == 0 else { continue }
    let bounds = (window[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    let area = width * height
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    if area > bestArea {
        bestArea = area
        bestNumber = number
    }
}

if bestNumber >= 0 {
    print(bestNumber)
} else {
    FileHandle.standardError.write("no on-screen window owned by \(owner)\n".data(using: .utf8)!)
    exit(1)
}
