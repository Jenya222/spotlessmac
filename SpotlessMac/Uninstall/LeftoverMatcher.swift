import Foundation

enum LeftoverMatcher {
    static func isExact(component: String, bundleID: String, rootName: String) -> Bool {
        switch rootName {
        case "Preferences":
            return component == "\(bundleID).plist"
        case "Saved Application State":
            return component == "\(bundleID).savedState"
        case "Group Containers":
            return false
        default:
            return component == bundleID
        }
    }

    static func isRelatedCandidate(component: String, bundleID: String) -> Bool {
        component == bundleID
            || component == "\(bundleID).plist"
            || component == "\(bundleID).savedState"
            || component.hasPrefix("\(bundleID).")
            || component.hasSuffix(".\(bundleID)")
    }
}
