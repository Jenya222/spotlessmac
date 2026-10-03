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

## Local testing: license bypass

`LicenseManager.canClean` returns `true` unconditionally under `#if DEBUG`, so the
activation dialog never blocks cleanups in Debug builds. The bypass requires the
**Debug configuration** (Xcode sets `-DDEBUG` only there).

**Preferred: `scripts/install-local-debug.sh`** — builds Debug, signs with a stable
`Apple Development` identity (not ad-hoc), and installs to `/Applications`. Signing
with a real certificate keeps the app's Designated Requirement constant across
rebuilds, so the **Full Disk Access grant survives rebuilds**. Requires an `Apple
Development` cert in Keychain (Xcode → Settings → Accounts → Manage Certificates);
override with `SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"` if more
than one is present.

```bash
./scripts/install-local-debug.sh
```

Plain `⌘R` in Xcode or a raw `xcodebuild -configuration Debug ... CODE_SIGNING_ALLOWED=NO`
build (no team assigned) signs **ad-hoc** instead — TCC then keys Full Disk Access to
the exact binary hash, so every rebuild invalidates the grant and re-triggers the FDA
prompt. Fine for quick iteration when FDA isn't needed; use the script above whenever
FDA-gated scanning (system logs/caches outside the home folder) needs to work reliably:

```bash
# From Xcode: open SpotlessMac.xcodeproj, then ⌘R (default scheme builds Debug)

# From the terminal: build Debug, then launch the .app
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
open build/DerivedData/Build/Products/Debug/SpotlessMac.app
```

`scripts/install-local.sh` and `scripts/build-release.sh` build **Release** — the
license check stays active there, which is intended. Do not remove the `#if DEBUG`
guard.

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
6. **Assistant never deletes or quits** — `SpotlessMac/Assistant/` has no access to deletion, process-quit (Memory section), process-spawn or Docker/uninstall APIs. Its only effect on the user's files and apps is the `stagePlan` closure, which marks existing scan items for the user's review (it also talks to the configured LLM endpoint and stores its own conversation file). Enforced by `AssistantIsolationTests`; never weaken its token list — extend it whenever a new type that deletes, spawns processes or quits apps is added.

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
| `ViewModels/ScanViewModel.swift` | Main scan ViewModel; drives scan + delete from the UI |
| `Assistant/AssistantViewModel.swift` | AI cleanup assistant; receives only a snapshot closure and `stagePlan` |
| `Assistant/AssistantGuard.swift` | Prompt-injection defences: local refusal of injection/internals requests, random-boundary fencing of snapshot and tool output, prompt-leak canary, hiding code and terminal commands in answers. Keep all four layers; extend the patterns rather than loosen them |
