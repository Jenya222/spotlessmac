# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# CLI build
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO

# Open in Xcode
open SpotlessMac.xcodeproj
```

Xcode 16.2, Swift 6.0, macOS 14 minimum target. No Mac App Store, no sandbox, Developer ID distribution.

## Architecture

```
SpotlessMac/App/          SwiftUI views — thin, no business logic
SpotlessMac/Models/       ScanItem, ScanCategory — value types, Sendable
SpotlessMac/ScanEngine/   Scanner protocol + ScanEngine actor + SafetyRules
SpotlessMac/ViewModels/   ScanViewModel (@Observable @MainActor)
```

**Data flow:** `ContentView → ScanViewModel → ScanEngine actor → [Scanner] → [ScanItem]`

### Concurrency model
- `ScanViewModel` is `@Observable @MainActor` — all UI state on main thread
- `ScanEngine` is an `actor` — file I/O runs off the main thread
- `ScanItem` and `ScanCategory` are `Sendable` value types that cross actor boundaries
- `Scanner` protocol requires `Sendable` conformance

## Safety rules (non-negotiable)

These invariants must be preserved in all changes:

1. **Whitelist only** — scanners search exclusively in `SafetyRules.allowedRoots`. No full-disk traversal.
2. **Trash only** — deletion uses `FileManager.trashItem` exclusively. `removeItem` is forbidden.
3. **Preview before delete** — user must see paths and sizes before any deletion is triggered.
4. **`SafetyRules.isSafe(_:)` gates every delete call** in `ScanEngine.delete()`.
5. **Never touch:** `/System`, `/private/var/vm` (swap), `/dev`, `/cores`, or anything outside the whitelist.

## Adding a new scanner

See `CachesScanner.swift` as the canonical pattern:
1. Create `struct MyScanner: Scanner` (struct = automatically `Sendable`)
2. Implement `scan() async throws -> [ScanItem]` using `FileManager.enumerator` for recursive size
3. Only enumerate paths that are in `SafetyRules.allowedRoots`
4. Register in `ScanEngine.scanners` array in `ScanEngine.swift`
5. Add a `ScanCategory` case if the category doesn't exist yet

**SwiftUI color tip:** In Swift 6, use `Color.accentColor` explicitly instead of `.accentColor` in `foregroundStyle` — the shorthand can't be inferred through the `ShapeStyle` protocol. For ternaries mixing color types, use the same `Color` on both branches (e.g., `Color.accentColor` vs `Color.gray`).

## Key files

| File | Purpose |
|------|---------|
| `ScanEngine/SafetyRules.swift` | Whitelist + forbidden paths — edit here to expand scan scope |
| `ScanEngine/ScanEngine.swift` | Registers scanners; only place `trashItem` calls live |
| `ScanEngine/Scanner.swift` | Protocol all scanners implement |
| `ViewModels/ScanViewModel.swift` | Only ViewModel; drives scan + delete from the UI |
