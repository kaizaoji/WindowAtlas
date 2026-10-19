import Foundation

struct WindowDescriptor {
    let title: String
    let frame: CGRect
}

// Titles alone are insufficient: terminals often have duplicate titles.
// Never silently activate another window merely because its geometry is nearby.
func matchingWindowIndex(title: String, appName: String, frame: CGRect, candidates: [WindowDescriptor], allowUniqueGeometry: Bool = false, geometryTolerance: CGFloat = 4) -> Int? {
    let exactGeometry = candidates.indices.filter { geometryDistance(candidates[$0].frame, frame) <= geometryTolerance }
    // Only used after revalidating the original CGWindowID against the live window server.
    // This permits animated terminal titles, and also untitled modal sheets.
    if allowUniqueGeometry, exactGeometry.count == 1 { return exactGeometry[0] }
    if allowUniqueGeometry, exactGeometry.count > 1 { return nil }
    let titled = candidates.indices.filter {
        candidates[$0].title == title || (candidates[$0].title.isEmpty && title == appName)
    }
    if titled.count > 1, titled.filter({ geometryDistance(candidates[$0].frame, frame) <= geometryTolerance }).count > 1 { return nil }
    return titled.min { geometryDistance(candidates[$0].frame, frame) < geometryDistance(candidates[$1].frame, frame) }
}

func geometryDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
}


func isSafeCancelTitle(_ title: String) -> Bool {
    ["取消", "Cancel"].contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
}
