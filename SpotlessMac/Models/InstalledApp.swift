import Foundation

// A discovered application bundle. Sendable — never holds an NSImage;
// the icon is loaded in the view layer from bundleURL.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String        // display name (CFBundleDisplayName / CFBundleName / filename)
    let bundleURL: URL      // the .app
    let bundleID: String?   // CFBundleIdentifier

    init(name: String, bundleURL: URL, bundleID: String?) {
        self.id = UUID()
        self.name = name
        self.bundleURL = bundleURL
        self.bundleID = bundleID
    }
}
