# Memory Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live «Память» section that shows memory pressure, swap and compression, attributes every process to the application responsible for it, and lets the user safely quit user applications. Also add a memory card on the Care dashboard.

**Architecture:** A new `SpotlessMac/Memory/` subsystem. Pure value models, Darwin readers (`host_statistics64`, `sysctl`, `proc_pid_rusage`, `responsibility_get_pid_responsible_for_pid` via `dlsym`) and a pure `ProcessGrouper` are combined by a `MemoryMonitor` actor. A `@MainActor @Observable MemoryViewModel` polls it every 2 s only while the section is visible. Quitting goes through `ProcessSafetyRules`, then `NSRunningApplication.terminate()`/`forceTerminate()`, never `kill(2)`.

**Tech Stack:** Swift 6.0, SwiftUI, Swift Charts, AppKit (`NSWorkspace`, `NSRunningApplication`), Darwin libproc/sysctl, XCTest. Xcode 16.2, macOS 14 minimum.

**Spec:** `docs/superpowers/specs/2026-10-02-memory-diagnostics-design.md`

**Pre-verified:** every Swift file in this plan was compiled with `swiftc -swift-version 6` (zero errors, zero warnings), and the full test suite (35 tests) passed in a scratch SwiftPM package on the target machine. A live sample of ~760 processes takes ~20–30 ms. Copy the code verbatim. If something does not compile inside the Xcode project, the cause is project wiring, not the code.

## Global Constraints

- Swift 6 language mode, strict concurrency: no `@preconcurrency`, no `nonisolated(unsafe)`. The one `@unchecked Sendable` is `ResponsibilityResolver` (an immutable C function pointer).
- macOS 14 minimum: no APIs newer than macOS 14.
- New files must be registered in `SpotlessMac.xcodeproj` with `scripts/xcodeproj-add.py` (the project has no synchronized folders; unregistered files are silently not compiled).
- No `kill(2)`, no `removeItem`, no privileged helpers, no `purge`. Quitting uses `NSRunningApplication` only.
- `ProcessSafetyRules.canQuit` gates every quit, and `MemoryViewModel.confirmQuit` refuses unless the state holds `.allowed`.
- Sampling runs only while the Memory section is visible (`onAppear` → `start()`, `onDisappear` → `stop()`), with a 2 s interval and a history of 150 points.
- UI copy is Russian. Code, comments and commit messages are English.
- Quitting is not gated by `LicenseManager`.
- Use `Color.accentColor` explicitly (never `.accentColor` shorthand) in `foregroundStyle`/`tint` (CLAUDE.md Swift 6 tip).
- The working tree contains many unrelated uncommitted changes. Every commit stages **only** the files named in its task (`git add <paths>` + `git commit -- <paths>` style). Never `git add -A` / `git commit -a`.

## Test command

Run one test class:

```bash
xcodebuild test -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" \
  -derivedDataPath build/DerivedData -only-testing:SpotlessMacTests/<ClassName> CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected success line: `** TEST SUCCEEDED **`. To run the whole suite, drop `-only-testing:…`.

Build only:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" \
  -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

## Review Focus

Failure modes that matter most for a real user. Each is pinned by a test in the owning task.

1. **Nested bundles.** `Docker.app/Contents/MacOS/Docker Desktop.app` (bundle id `com.electron.dockerdesktop`) and `Docker.app/Contents/MacOS/com.docker.backend` must form **one** Docker group, together with the VM process attributed by responsibility. Pinned: `testDockerProcessesCollapseIntoOneGroup` (Task 1).
2. **Code-sign clone.** Chrome's main process runs from `/private/var/folders/…/Google Chrome.app.bundle/…`, which has no `.app` component. Without the running-app lookup, Chrome's 65 processes would fall into «other». Pinned: `testChromeCodeSignCloneResolvesThroughRunningApp` (Task 1).
3. **User apps that live under `/System`.** Terminal and Activity Monitor (`/System/Applications`) and Safari (`/System/Volumes/Preboot/Cryptexes/…`) must be user apps that can be quit. Finder/Dock must stay protected. Pinned: `testRegularAppUnderSystemIsUserApp` (Task 1), `testRegularAppUnderSystemIsAllowed` and `testProtectedComponentsAreDenied` (Task 3).
4. **Rows jumping under the cursor.** While a row is expanded, live re-sorting every 2 s would move it. Order is kept for at most 10 s, new groups are appended and vanished ones dropped. Pinned: `testOrderKeepsPreviousPositionsUntilResort` and `testApplyResortsAtMostEveryTenSeconds` (Task 4).
5. **Quit flow lying or overreaching.** Quit must never touch system/CLI groups, SpotlessMac itself or other users' processes. An app that ignores `terminate()` must lead to an explicit force-quit offer, not a silent success. Pinned: `testDeniedQuitNeverTerminates`, `testUnresponsiveAppOffersForceQuit`, `testSpotlessMacItselfIsDenied` and `testForeignUIDIsDenied` (Tasks 3–4).

---

### Task 1: Project helper, memory models and ProcessGrouper

**Files:**
- Create: `scripts/xcodeproj-add.py` (already present in the working tree, untracked; verify the content matches below and commit it)
- Create: `SpotlessMac/Memory/MemoryModels.swift`
- Create: `SpotlessMac/Memory/ProcessGrouper.swift`
- Create: `SpotlessMacTests/MemoryFixtures.swift`
- Test: `SpotlessMacTests/ProcessGrouperTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj` (via the script only)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MemoryPressure: Int { unknown=0, normal=1, warning=2, critical=4 }`, `init(sysctlLevel: Int32?)`
  - `struct SystemMemorySnapshot` (physical, appMemory, wired, compressed, cachedFiles, free, swapUsed, swapTotal: `UInt64`; pressure; computed `used`)
  - `struct ProcessMemorySample` (pid, ppid, uid: `uid_t?`, name, path: `String?`, responsiblePID: `pid_t?`, footprint, resident, isPartial; computed `pushedOut`)
  - `struct RunningAppInfo` (pid, bundlePath = outermost `.app`, bundleIdentifier, policy: `ActivationPolicy { regular, accessory, prohibited }`)
  - `struct AppMemoryGroup: Identifiable` (id, displayName, kind: `Kind { userApp, system, other }`, bundlePath, processes; computed footprint, pushedOut, hasPartialData)
  - `struct MemorySample` (date, system, groups, runningApps; `func runningApps(in: AppMemoryGroup) -> [RunningAppInfo]`)
  - `enum BundlePath { systemPrefixes; outermostApp(in:) -> String?; isSystem(_:) -> Bool }`
  - `enum ProcessGrouper { static let systemGroupID = "system"; static func group(_:runningApps:currentUID:) -> [AppMemoryGroup] }`. The result is sorted by footprint, descending.
  - Test helper `enum MemoryFixtures` (process / app / userGroup / system / sample builders)

- [ ] **Step 1: Commit the project helper**

`scripts/xcodeproj-add.py` already exists in the working tree. Confirm that it matches this content (overwrite it if it differs):

```python
#!/usr/bin/env python3
"""Register new Swift files in SpotlessMac.xcodeproj.

Usage:
  scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/Foo.swift [...]
  scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/FooTests.swift [...]

The group is looked up by name; a missing app subgroup is created under the
SpotlessMac group. IDs are derived from the file path, so re-running is a no-op.
"""
import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "SpotlessMac.xcodeproj" / "project.pbxproj"
SOURCES_PHASE = {"app": "BB000002000000000000BB00", "tests": "BB100002000000000000BB00"}
APP_ROOT_GROUP = "AA000003000000000000AA00"


def make_id(kind: str, key: str) -> str:
    return hashlib.md5(f"{kind}:{key}".encode()).hexdigest()[:24].upper()


def insert_after(text: str, marker: str, line: str) -> str:
    index = text.index(marker) + len(marker)
    return text[:index] + "\n" + line + text[index:]


def add_child(text: str, group_id: str, child_line: str) -> str:
    match = re.search(re.escape(group_id) + r" /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(", text)
    if not match:
        raise SystemExit(f"group {group_id} not found")
    return text[:match.end()] + "\n" + child_line + text[match.end():]


def find_group(text: str, name: str):
    match = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(name) + r" \*/ = \{\n\t\t\tisa = PBXGroup;", text)
    return match.group(1) if match else None


def ensure_group(text: str, name: str):
    group_id = find_group(text, name)
    if group_id:
        return text, group_id
    group_id = make_id("group", name)
    block = (f"\t\t{group_id} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
             f"\t\t\tpath = {name};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    text = insert_after(text, "/* Begin PBXGroup section */", block)
    text = add_child(text, APP_ROOT_GROUP, f"\t\t\t\t{group_id} /* {name} */,")
    return text, group_id


def main() -> None:
    target, group_name, *files = sys.argv[1:]
    text = PROJECT.read_text()
    text, group_id = ensure_group(text, group_name)
    for file in files:
        name = Path(file).name
        ref_id, build_id = make_id("ref", file), make_id("build", file)
        if ref_id in text:
            continue
        text = insert_after(text, "/* Begin PBXFileReference section */",
                            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
                            f"path = {name}; sourceTree = \"<group>\"; }};")
        text = insert_after(text, "/* Begin PBXBuildFile section */",
                            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};")
        text = add_child(text, group_id, f"\t\t\t\t{ref_id} /* {name} */,")
        phase = SOURCES_PHASE[target]
        marker = f"{phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ("
        if marker not in text:
            raise SystemExit(f"sources phase {phase} not found")
        text = insert_after(text, marker, f"\t\t\t\t{build_id} /* {name} in Sources */,")
    PROJECT.write_text(text)


if __name__ == "__main__":
    main()
```

```bash
chmod +x scripts/xcodeproj-add.py
git add scripts/xcodeproj-add.py
git commit -m "chore: add helper to register files in the Xcode project" -- scripts/xcodeproj-add.py
```

- [ ] **Step 2: Write the fixtures and failing grouper tests**

`SpotlessMacTests/MemoryFixtures.swift`:

```swift
import Darwin
import Foundation
@testable import SpotlessMac

enum MemoryFixtures {
    static let me: uid_t = 501

    static func process(
        _ pid: pid_t, ppid: pid_t = 1, uid: uid_t? = 501, name: String = "proc",
        path: String? = nil, responsible: pid_t? = nil,
        footprint: UInt64 = 100, resident: UInt64 = 100, partial: Bool = false
    ) -> ProcessMemorySample {
        ProcessMemorySample(pid: pid, ppid: ppid, uid: uid, name: name, path: path, responsiblePID: responsible,
                            footprint: footprint, resident: resident, isPartial: partial)
    }

    static func app(
        _ pid: pid_t, _ bundlePath: String, id: String? = nil,
        policy: RunningAppInfo.ActivationPolicy = .regular
    ) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundlePath: bundlePath, bundleIdentifier: id, policy: policy)
    }

    static func userGroup(_ bundlePath: String, processes: [ProcessMemorySample]) -> AppMemoryGroup {
        AppMemoryGroup(id: bundlePath, displayName: URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent,
                       kind: .userApp, bundlePath: bundlePath, processes: processes)
    }

    static func system(
        physical: UInt64 = 16 << 30, compressed: UInt64 = 0, swapUsed: UInt64 = 0,
        pressure: MemoryPressure = .normal
    ) -> SystemMemorySnapshot {
        SystemMemorySnapshot(physical: physical, appMemory: 4 << 30, wired: 2 << 30, compressed: compressed,
                             cachedFiles: 1 << 30, free: 1 << 30, swapUsed: swapUsed, swapTotal: 20 << 30,
                             pressure: pressure)
    }

    static func sample(
        at date: Date, groups: [AppMemoryGroup] = [], runningApps: [RunningAppInfo] = [],
        swapUsed: UInt64 = 0
    ) -> MemorySample {
        MemorySample(date: date, system: system(swapUsed: swapUsed), groups: groups, runningApps: runningApps)
    }
}
```

`SpotlessMacTests/ProcessGrouperTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class ProcessGrouperTests: XCTestCase {
    private typealias F = MemoryFixtures

    func testOutermostAppNormalizesNestedBundles() {
        XCTAssertEqual(BundlePath.outermostApp(in: "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop"),
                       "/Applications/Docker.app")
        XCTAssertEqual(BundlePath.outermostApp(in: "/Applications/Foo.app"), "/Applications/Foo.app")
        XCTAssertNil(BundlePath.outermostApp(in: "/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"))
        XCTAssertNil(BundlePath.outermostApp(in: "/usr/libexec/trustd"))
    }

    func testDockerProcessesCollapseIntoOneGroup() {
        let docker = "/Applications/Docker.app"
        let processes = [
            F.process(3246, name: "Docker Desktop", path: docker + "/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop", footprint: 40),
            F.process(3281, ppid: 3246, name: "Docker Desktop Helper",
                      path: docker + "/Contents/MacOS/Docker Desktop.app/Contents/Frameworks/Docker Desktop Helper.app/Contents/MacOS/Docker Desktop Helper",
                      responsible: 3246),
            F.process(29234, name: "com.docker.backend", path: docker + "/Contents/MacOS/com.docker.backend"),
            F.process(29388, ppid: 29234, name: "docker-agent", path: docker + "/Contents/Resources/cli-plugins/docker-agent", responsible: 29234),
            F.process(500, name: "com.apple.Virtualization.VirtualMachine",
                      path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
                      responsible: 29234, footprint: 8000),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(3246, docker, id: "com.electron.dockerdesktop")], currentUID: F.me)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, docker)
        XCTAssertEqual(groups[0].displayName, "Docker")
        XCTAssertEqual(groups[0].kind, .userApp)
        XCTAssertEqual(groups[0].processes.count, 5)
        XCTAssertEqual(groups[0].processes.first?.pid, 500, "processes are sorted by footprint")
    }

    func testChromeCodeSignCloneResolvesThroughRunningApp() {
        let chrome = "/Applications/Google Chrome.app"
        let processes = [
            F.process(10, name: "Google Chrome", path: "/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"),
            F.process(11, ppid: 10, name: "Google Chrome Helper (Renderer)",
                      path: chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                      responsible: 10),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(10, chrome)], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), [chrome])
        XCTAssertEqual(groups[0].processes.count, 2)
    }

    func testWithoutResponsibilityParentChainFindsTheApp() {
        let processes = [
            F.process(20, name: "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo"),
            F.process(21, ppid: 20, name: "tool", path: "/usr/local/bin/tool"),
            F.process(22, ppid: 21, name: "worker", path: nil),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), ["/Applications/Foo.app"])
        XCTAssertEqual(groups[0].processes.count, 3)
    }

    func testRegularAppUnderSystemIsUserApp() {
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let processes = [F.process(30, name: "Terminal", path: terminal + "/Contents/MacOS/Terminal")]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(30, terminal, id: "com.apple.Terminal")], currentUID: F.me)
        XCTAssertEqual(groups.first?.kind, .userApp)
        XCTAssertEqual(groups.first?.displayName, "Terminal")
    }

    func testRootOtherUsersAndSystemBundlesGoToSystem() {
        let processes = [
            F.process(40, uid: 0, name: "trustd", path: "/usr/libexec/trustd"),
            F.process(41, uid: 205, name: "locationd", path: "/usr/libexec/locationd"),
            F.process(42, name: "Spotlight", path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"),
            F.process(43, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), [ProcessGrouper.systemGroupID])
        XCTAssertEqual(groups[0].kind, .system)
        XCTAssertEqual(groups[0].processes.count, 4)
    }

    func testUserCommandLineProcessesGroupByName() {
        let processes = [
            F.process(50, name: "claude", path: "/Users/u/.local/share/claude/versions/2.1.285"),
            F.process(51, name: "claude", path: "/Users/u/.local/share/claude/versions/2.1.287"),
            F.process(52, name: "node", path: "/opt/homebrew/bin/node"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(Set(groups.map(\.id)), ["other:claude", "other:node"])
        XCTAssertEqual(groups.first { $0.id == "other:claude" }?.processes.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.kind == .other })
    }

    func testParentCycleTerminates() {
        let processes = [
            F.process(60, ppid: 61, name: "loop"),
            F.process(61, ppid: 60, name: "loop"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), ["other:loop"])
    }

    func testPartialProcessesAreKept() {
        let processes = [F.process(70, uid: nil, name: "secret", path: nil, footprint: 0, resident: 0, partial: true)]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].hasPartialData)
    }

    func testGroupsAreSortedAndTotalsSummed() {
        let processes = [
            F.process(80, name: "A", path: "/Applications/A.app/Contents/MacOS/A", footprint: 300, resident: 100),
            F.process(81, name: "B", path: "/Applications/B.app/Contents/MacOS/B", footprint: 500, resident: 500),
            F.process(82, ppid: 80, name: "A Helper", path: "/Applications/A.app/Contents/MacOS/A Helper", footprint: 400, resident: 100),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.displayName), ["A", "B"])
        XCTAssertEqual(groups[0].footprint, 700)
        XCTAssertEqual(groups[0].pushedOut, 500)
        XCTAssertEqual(groups[1].pushedOut, 0)
    }
}
```

Register both:

```bash
python3 scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/MemoryFixtures.swift SpotlessMacTests/ProcessGrouperTests.swift
```

- [ ] **Step 3: Run the tests and verify they fail**

Run the test command with `-only-testing:SpotlessMacTests/ProcessGrouperTests`.
Expected: build failure, `cannot find 'ProcessMemorySample' in scope` (or a similar missing-type error).

- [ ] **Step 4: Implement the models and the grouper**

`SpotlessMac/Memory/MemoryModels.swift`:

```swift
import Darwin
import Foundation

enum MemoryPressure: Int, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    init(sysctlLevel: Int32?) {
        self = sysctlLevel.flatMap { MemoryPressure(rawValue: Int($0)) } ?? .unknown
    }
}

struct SystemMemorySnapshot: Sendable, Equatable {
    var physical: UInt64
    var appMemory: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cachedFiles: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure

    /// Matches Activity Monitor's "Memory Used".
    var used: UInt64 { appMemory + wired + compressed }
}

struct ProcessMemorySample: Sendable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t?
    let name: String
    let path: String?
    let responsiblePID: pid_t?
    let footprint: UInt64
    let resident: UInt64
    /// True when the memory figures could not be read (other users, root).
    let isPartial: Bool

    /// Estimate of the part held compressed or in swap.
    var pushedOut: UInt64 { footprint > resident ? footprint - resident : 0 }
}

struct RunningAppInfo: Sendable, Equatable {
    let pid: pid_t
    /// Outermost `*.app` that contains the application bundle.
    let bundlePath: String
    let bundleIdentifier: String?
    let policy: ActivationPolicy

    enum ActivationPolicy: Sendable, Equatable { case regular, accessory, prohibited }
}

struct AppMemoryGroup: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case userApp, system, other }

    let id: String
    let displayName: String
    let kind: Kind
    /// Outermost bundle path for `.userApp` groups.
    let bundlePath: String?
    /// Processes sorted by footprint, largest first.
    let processes: [ProcessMemorySample]

    var footprint: UInt64 { processes.reduce(0) { $0 + $1.footprint } }
    var pushedOut: UInt64 { processes.reduce(0) { $0 + $1.pushedOut } }
    var hasPartialData: Bool { processes.contains { $0.isPartial } }
}

struct MemorySample: Sendable, Equatable {
    let date: Date
    let system: SystemMemorySnapshot
    let groups: [AppMemoryGroup]
    let runningApps: [RunningAppInfo]

    func runningApps(in group: AppMemoryGroup) -> [RunningAppInfo] {
        guard let path = group.bundlePath else { return [] }
        return runningApps.filter { $0.bundlePath == path }
    }
}

enum BundlePath {
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// `/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/...` → `/Applications/Docker.app`.
    static func outermostApp(in path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(String(component))
            if component.hasSuffix(".app") { return "/" + components.joined(separator: "/") }
        }
        return nil
    }

    static func isSystem(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }
}
```

`SpotlessMac/Memory/ProcessGrouper.swift`:

```swift
import Darwin
import Foundation

/// Collapses processes into the application responsible for them.
enum ProcessGrouper {
    static let systemGroupID = "system"
    private static let maxParentDepth = 32

    static func group(
        _ processes: [ProcessMemorySample],
        runningApps: [RunningAppInfo],
        currentUID: uid_t
    ) -> [AppMemoryGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let appByPID = Dictionary(runningApps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let regularBundles = Set(runningApps.filter { $0.policy == .regular }.map(\.bundlePath))

        func bundle(of pid: pid_t) -> String? {
            if let app = appByPID[pid] { return app.bundlePath }
            return byPID[pid]?.path.flatMap(BundlePath.outermostApp(in:))
        }

        func resolveBundle(for process: ProcessMemorySample) -> String? {
            if let responsible = process.responsiblePID, responsible != process.pid,
               let path = bundle(of: responsible) {
                return path
            }
            var current: pid_t? = process.pid
            var visited = Set<pid_t>()
            while let pid = current, pid > 1, visited.count < maxParentDepth, visited.insert(pid).inserted {
                if let path = bundle(of: pid) { return path }
                current = byPID[pid]?.ppid
            }
            return nil
        }

        var userApps: [String: [ProcessMemorySample]] = [:]
        var others: [String: [ProcessMemorySample]] = [:]
        var system: [ProcessMemorySample] = []

        for process in processes {
            let path = resolveBundle(for: process)
            if let path, regularBundles.contains(path) || !BundlePath.isSystem(path) {
                userApps[path, default: []].append(process)
            } else if path != nil || process.uid != currentUID || process.path.map(BundlePath.isSystem) == true {
                system.append(process)
            } else {
                others[process.name, default: []].append(process)
            }
        }

        func sorted(_ list: [ProcessMemorySample]) -> [ProcessMemorySample] {
            list.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
        }

        var groups = userApps.map { path, list in
            AppMemoryGroup(
                id: path,
                displayName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                kind: .userApp, bundlePath: path, processes: sorted(list)
            )
        }
        groups += others.map { name, list in
            AppMemoryGroup(id: "other:" + name, displayName: name, kind: .other, bundlePath: nil, processes: sorted(list))
        }
        if !system.isEmpty {
            groups.append(AppMemoryGroup(id: systemGroupID, displayName: "Система", kind: .system,
                                         bundlePath: nil, processes: sorted(system)))
        }
        return groups.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }
}
```

Register (this also creates the `Memory` group under `SpotlessMac`):

```bash
python3 scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/MemoryModels.swift SpotlessMac/Memory/ProcessGrouper.swift
plutil -lint SpotlessMac.xcodeproj/project.pbxproj
```

- [ ] **Step 5: Run the tests and verify they pass**

Run the test command with `-only-testing:SpotlessMacTests/ProcessGrouperTests`.
Expected: `** TEST SUCCEEDED **`, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/Memory SpotlessMacTests/MemoryFixtures.swift SpotlessMacTests/ProcessGrouperTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): add memory models and process-to-app grouping" -- SpotlessMac/Memory SpotlessMacTests/MemoryFixtures.swift SpotlessMacTests/ProcessGrouperTests.swift SpotlessMac.xcodeproj/project.pbxproj
```

> Note: `project.pbxproj` already has unrelated uncommitted edits in this working tree. Committing it includes them. Before committing, run `git diff --cached --stat` and tell your coordinator if that is a concern. Do not try to split hunks interactively.

---

### Task 2: System and process readers, MemoryMonitor

**Files:**
- Create: `SpotlessMac/Memory/SystemMemoryReader.swift`
- Create: `SpotlessMac/Memory/ProcessMemoryReader.swift` (contains `ResponsibilityResolver`, `ProcessMemoryReader`, `RunningAppsReader`)
- Create: `SpotlessMac/Memory/MemoryMonitor.swift`
- Test: `SpotlessMacTests/SystemMemoryReaderTests.swift`

**Interfaces:**
- Consumes: models from Task 1, `ProcessGrouper.group`.
- Produces:
  - `struct VMPageCounts` (free, wired, internalPages, externalPages, purgeable, compressor: `UInt64`, all defaulting to 0)
  - `enum SystemMemoryReader { static func current() -> SystemMemorySnapshot; static func snapshot(pages:pageSize:physical:swapUsed:swapTotal:pressureLevel:) -> SystemMemorySnapshot }`
  - `struct ResponsibilityResolver: @unchecked Sendable { static let live; func responsiblePID(for: pid_t) -> pid_t? }`
  - `enum ProcessMemoryReader { static func readAll(responsibility: ResponsibilityResolver = .live) -> [ProcessMemorySample] }`
  - `enum RunningAppsReader { static func current() -> [RunningAppInfo] }`
  - `actor MemoryMonitor { func sample() -> MemorySample }`

- [ ] **Step 1: Write the failing tests**

`SpotlessMacTests/SystemMemoryReaderTests.swift`:

```swift
import Darwin
import XCTest
@testable import SpotlessMac

final class SystemMemoryReaderTests: XCTestCase {
    func testSnapshotMatchesActivityMonitorBreakdown() {
        let pages = VMPageCounts(free: 50, wired: 200, internalPages: 1000, externalPages: 300, purgeable: 100, compressor: 400)
        let snapshot = SystemMemoryReader.snapshot(pages: pages, pageSize: 16384, physical: 1 << 34,
                                                   swapUsed: 7, swapTotal: 9, pressureLevel: 2)
        XCTAssertEqual(snapshot.appMemory, 900 * 16384)
        XCTAssertEqual(snapshot.cachedFiles, 400 * 16384)
        XCTAssertEqual(snapshot.wired, 200 * 16384)
        XCTAssertEqual(snapshot.compressed, 400 * 16384)
        XCTAssertEqual(snapshot.used, (900 + 200 + 400) * 16384)
        XCTAssertEqual(snapshot.swapUsed, 7)
        XCTAssertEqual(snapshot.swapTotal, 9)
        XCTAssertEqual(snapshot.pressure, .warning)
    }

    func testPurgeableAboveInternalClampsToZero() {
        let pages = VMPageCounts(internalPages: 10, purgeable: 20)
        let snapshot = SystemMemoryReader.snapshot(pages: pages, pageSize: 4096, physical: 1, swapUsed: 0, swapTotal: 0, pressureLevel: nil)
        XCTAssertEqual(snapshot.appMemory, 0)
    }

    func testPressureLevelMapping() {
        XCTAssertEqual(MemoryPressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 3), .unknown)
        XCTAssertEqual(MemoryPressure(sysctlLevel: nil), .unknown)
    }

    func testLiveReadersReturnPlausibleData() {
        let system = SystemMemoryReader.current()
        XCTAssertEqual(system.physical, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(system.used, 0)
        XCTAssertNotEqual(system.pressure, .unknown)

        let processes = ProcessMemoryReader.readAll()
        let me = processes.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertFalse(me?.isPartial ?? true)
        XCTAssertGreaterThan(me?.footprint ?? 0, 0)
        XCTAssertEqual(me?.uid, getuid())
    }
}
```

```bash
python3 scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/SystemMemoryReaderTests.swift
```

- [ ] **Step 2: Run the tests and verify they fail**

Run the test command with `-only-testing:SpotlessMacTests/SystemMemoryReaderTests`.
Expected: build failure, `cannot find 'VMPageCounts' in scope`.

- [ ] **Step 3: Implement the readers and the monitor**

`SpotlessMac/Memory/SystemMemoryReader.swift`:

```swift
import Darwin
import Foundation

/// Page counts from `host_statistics64(HOST_VM_INFO64)`.
struct VMPageCounts: Sendable, Equatable {
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var internalPages: UInt64 = 0
    var externalPages: UInt64 = 0
    var purgeable: UInt64 = 0
    var compressor: UInt64 = 0
}

enum SystemMemoryReader {
    static func current() -> SystemMemorySnapshot {
        let swap = readSwap()
        return snapshot(
            pages: readPages() ?? VMPageCounts(),
            pageSize: UInt64(getpagesize()),
            physical: ProcessInfo.processInfo.physicalMemory,
            swapUsed: swap.used, swapTotal: swap.total,
            pressureLevel: readPressureLevel()
        )
    }

    /// Same breakdown as Activity Monitor: app = internal − purgeable,
    /// cached files = external + purgeable.
    static func snapshot(
        pages: VMPageCounts, pageSize: UInt64, physical: UInt64,
        swapUsed: UInt64, swapTotal: UInt64, pressureLevel: Int32?
    ) -> SystemMemorySnapshot {
        let internalPages = pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0
        return SystemMemorySnapshot(
            physical: physical,
            appMemory: internalPages * pageSize,
            wired: pages.wired * pageSize,
            compressed: pages.compressor * pageSize,
            cachedFiles: (pages.externalPages + pages.purgeable) * pageSize,
            free: pages.free * pageSize,
            swapUsed: swapUsed, swapTotal: swapTotal,
            pressure: MemoryPressure(sysctlLevel: pressureLevel)
        )
    }

    private static func readPages() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            free: UInt64(stats.free_count),
            wired: UInt64(stats.wire_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeable: UInt64(stats.purgeable_count),
            compressor: UInt64(stats.compressor_page_count)
        )
    }

    private static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func readPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }
}
```

`SpotlessMac/Memory/ProcessMemoryReader.swift`:

```swift
import AppKit
import Darwin

/// Wraps the private `responsibility_get_pid_responsible_for_pid`, which
/// Activity Monitor uses to attribute XPC services and VMs to their app.
/// Missing symbol → every lookup returns nil and attribution falls back
/// to bundle paths and the parent chain.
struct ResponsibilityResolver: @unchecked Sendable {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    private let function: Function?

    static let live = ResponsibilityResolver()

    private init() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        function = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Function.self) }
    }

    func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}

enum ProcessMemoryReader {
    static func readAll(responsibility: ResponsibilityResolver = .live) -> [ProcessMemorySample] {
        listPIDs().compactMap { read(pid: $0, responsibility: responsibility) }
    }

    private static func listPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    private static func read(pid: pid_t, responsibility: ResponsibilityResolver) -> ProcessMemorySample? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

        let path = string(capacity: Int(MAXPATHLEN) * 4) { proc_pidpath(pid, $0, $1) }
        let name = argumentZero(pid: pid)
            ?? string(capacity: 256) { proc_name(pid, $0, $1) }
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard hasBSD || path != nil || name != nil else { return nil } // process exited

        var usage = rusage_info_v4()
        let rusageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let hasUsage = rusageResult == 0

        return ProcessMemorySample(
            pid: pid,
            ppid: hasBSD ? pid_t(bsd.pbi_ppid) : 0,
            uid: hasBSD ? bsd.pbi_uid : nil,
            name: name ?? "pid \(pid)",
            path: path,
            responsiblePID: responsibility.responsiblePID(for: pid),
            footprint: hasUsage ? usage.ri_phys_footprint : 0,
            resident: hasUsage ? usage.ri_resident_size : 0,
            isPartial: !hasUsage
        )
    }

    /// Last path component of argv[0] — `claude` rather than the versioned
    /// binary name `2.1.285`. Only readable for the current user's processes.
    private static func argumentZero(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), exec path, NUL padding, argv[0], ...
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        let argument = String(decoding: buffer[start..<index], as: UTF8.self)
        let name = URL(fileURLWithPath: argument).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func string(
        capacity: Int, _ fill: (UnsafeMutableRawPointer, UInt32) -> Int32
    ) -> String? {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBytes { fill($0.baseAddress!, UInt32(capacity)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

enum RunningAppsReader {
    private static func policy(_ policy: NSApplication.ActivationPolicy) -> RunningAppInfo.ActivationPolicy {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        default: return .prohibited
        }
    }

    static func current() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL,
                  let bundlePath = BundlePath.outermostApp(in: url.path) else { return nil }
            return RunningAppInfo(
                pid: app.processIdentifier,
                bundlePath: bundlePath,
                bundleIdentifier: app.bundleIdentifier,
                policy: policy(app.activationPolicy)
            )
        }
    }
}
```

`SpotlessMac/Memory/MemoryMonitor.swift`:

```swift
import Darwin
import Foundation

/// Takes one memory sample off the main thread.
actor MemoryMonitor {
    func sample() -> MemorySample {
        let system = SystemMemoryReader.current()
        let processes = ProcessMemoryReader.readAll()
        let runningApps = RunningAppsReader.current()
        return MemorySample(
            date: Date(),
            system: system,
            groups: ProcessGrouper.group(processes, runningApps: runningApps, currentUID: getuid()),
            runningApps: runningApps
        )
    }
}
```

Notes for the implementer:
- `getpagesize()` is used instead of `vm_kernel_page_size`, because the latter is a global `var` that Swift 6 rejects as not concurrency-safe.
- `argumentZero` reads `KERN_PROCARGS2` so Claude Code's versioned binary (`~/.local/share/claude/versions/2.1.285`) is named `claude`. It returns nil for other users' processes, which is expected.
- `UnsafeMutableRawPointer(bitPattern: -2)` is `RTLD_DEFAULT`, which Swift does not import.

```bash
python3 scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/SystemMemoryReader.swift SpotlessMac/Memory/ProcessMemoryReader.swift SpotlessMac/Memory/MemoryMonitor.swift
```

- [ ] **Step 4: Run the tests and verify they pass**

Run the test command with `-only-testing:SpotlessMacTests/SystemMemoryReaderTests`.
Expected: `** TEST SUCCEEDED **`, 4 tests. `testLiveReadersReturnPlausibleData` reads the test host process itself, so it needs no privileges.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Memory SpotlessMacTests/SystemMemoryReaderTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): read system memory, per-process footprint and responsibility" -- SpotlessMac/Memory SpotlessMacTests/SystemMemoryReaderTests.swift SpotlessMac.xcodeproj/project.pbxproj
```

---

### Task 3: ProcessSafetyRules and MemoryVerdict

**Files:**
- Create: `SpotlessMac/Memory/ProcessSafetyRules.swift`
- Create: `SpotlessMac/Memory/MemoryVerdict.swift`
- Test: `SpotlessMacTests/ProcessSafetyRulesTests.swift`
- Test: `SpotlessMacTests/MemoryVerdictTests.swift`

**Interfaces:**
- Consumes: models and `BundlePath` from Task 1.
- Produces:
  - `enum QuitDecision: Equatable { case allowed; case denied(String) }`
  - `enum ProcessSafetyRules { static func canQuit(_ group: AppMemoryGroup, runningApps: [RunningAppInfo], currentUID: uid_t, ownBundlePath: String, ownPID: pid_t) -> QuitDecision }`
  - `enum MemoryVerdict { static func text(system:groups:) -> String; static func format(_ bytes: UInt64) -> String }`

- [ ] **Step 1: Write the failing tests**

`SpotlessMacTests/ProcessSafetyRulesTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class ProcessSafetyRulesTests: XCTestCase {
    private typealias F = MemoryFixtures
    private let own = "/Applications/SpotlessMac.app"

    private func decide(_ group: AppMemoryGroup, _ apps: [RunningAppInfo]) -> QuitDecision {
        ProcessSafetyRules.canQuit(group, runningApps: apps, currentUID: F.me, ownBundlePath: own, ownPID: 9999)
    }

    func testRegularUserAppIsAllowed() {
        let group = F.userGroup("/Applications/Slack.app", processes: [F.process(1, name: "Slack")])
        XCTAssertEqual(decide(group, [F.app(1, "/Applications/Slack.app")]), .allowed)
    }

    func testSystemAndCommandLineGroupsAreDeniedWithDifferentReasons() {
        let system = AppMemoryGroup(id: "system", displayName: "Система", kind: .system, bundlePath: nil, processes: [])
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil, processes: [])
        guard case .denied(let systemReason) = decide(system, []),
              case .denied(let otherReason) = decide(other, []) else { return XCTFail("must deny") }
        XCTAssertNotEqual(systemReason, otherReason)
    }

    func testRegularAppUnderSystemIsAllowed() {
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let group = F.userGroup(terminal, processes: [F.process(11, name: "Terminal")])
        XCTAssertEqual(decide(group, [F.app(11, terminal, id: "com.apple.Terminal")]), .allowed)
    }

    func testSpotlessMacItselfIsDenied() {
        let byPath = F.userGroup(own, processes: [F.process(2)])
        XCTAssertNotEqual(decide(byPath, [F.app(2, own)]), .allowed)
        let byPID = F.userGroup("/Applications/X.app", processes: [F.process(9999)])
        XCTAssertNotEqual(decide(byPID, [F.app(9999, "/Applications/X.app")]), .allowed)
    }

    func testForeignUIDIsDenied() {
        let group = F.userGroup("/Applications/X.app", processes: [F.process(3), F.process(4, uid: 0)])
        XCTAssertNotEqual(decide(group, [F.app(3, "/Applications/X.app")]), .allowed)
    }

    func testProtectedComponentsAreDenied() {
        let finder = "/System/Library/CoreServices/Finder.app"
        let byID = F.userGroup(finder, processes: [F.process(5, name: "Finder")])
        XCTAssertNotEqual(decide(byID, [F.app(5, finder, id: "com.apple.finder")]), .allowed)
        let byName = F.userGroup("/Applications/Weird.app", processes: [F.process(6, name: "WindowServer")])
        XCTAssertNotEqual(decide(byName, [F.app(6, "/Applications/Weird.app")]), .allowed)
    }

    func testAppWithoutRunningApplicationIsDenied() {
        let group = F.userGroup("/Applications/Xcode.app", processes: [F.process(7, name: "SourceKitService")])
        XCTAssertNotEqual(decide(group, []), .allowed)
    }

    func testActivationPolicyRules() {
        let menuBar = F.userGroup("/Applications/Menu.app", processes: [F.process(8)])
        XCTAssertEqual(decide(menuBar, [F.app(8, "/Applications/Menu.app", policy: .accessory)]), .allowed)

        let systemAgent = F.userGroup("/System/Library/CoreServices/Agent.app", processes: [F.process(9)])
        XCTAssertNotEqual(decide(systemAgent, [F.app(9, "/System/Library/CoreServices/Agent.app", policy: .accessory)]), .allowed)

        let background = F.userGroup("/Applications/Daemon.app", processes: [F.process(10)])
        XCTAssertNotEqual(decide(background, [F.app(10, "/Applications/Daemon.app", policy: .prohibited)]), .allowed)
    }
}
```

`SpotlessMacTests/MemoryVerdictTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class MemoryVerdictTests: XCTestCase {
    private typealias F = MemoryFixtures

    private let groups = [
        F.userGroup("/Applications/Google Chrome.app", processes: [F.process(1, footprint: 10 << 30)]),
        F.userGroup("/Applications/Slack.app", processes: [F.process(2, footprint: 2 << 30)]),
        F.userGroup("/Applications/Notes.app", processes: [F.process(3, footprint: 1 << 30)]),
    ]

    func testCalmSystem() {
        XCTAssertEqual(MemoryVerdict.text(system: F.system(), groups: groups), "Памяти достаточно.")
    }

    func testHeavySwapNamesTopTwoApps() {
        let text = MemoryVerdict.text(system: F.system(swapUsed: 9 << 30), groups: groups)
        XCTAssertTrue(text.hasPrefix("Своп "), text)
        XCTAssertTrue(text.contains("Google Chrome"), text)
        XCTAssertTrue(text.contains("Slack"), text)
        XCTAssertFalse(text.contains("Notes"), text)
    }

    func testCriticalPressureWithoutSwap() {
        let text = MemoryVerdict.text(system: F.system(pressure: .critical), groups: groups)
        XCTAssertTrue(text.hasPrefix("Своп "), text)
    }

    func testWarningPressure() {
        let text = MemoryVerdict.text(system: F.system(pressure: .warning), groups: groups)
        XCTAssertTrue(text.hasPrefix("Память под нагрузкой."), text)
    }

    func testCommandLineGroupsAreNotNamedAsHolders() {
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil,
                                   processes: [F.process(9, footprint: 20 << 30)])
        let text = MemoryVerdict.text(system: F.system(swapUsed: 9 << 30), groups: [other])
        XCTAssertFalse(text.contains("node"), text)
    }
}
```

```bash
python3 scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/ProcessSafetyRulesTests.swift SpotlessMacTests/MemoryVerdictTests.swift
```

- [ ] **Step 2: Run the tests and verify they fail**

Run the test command twice: once with `-only-testing:SpotlessMacTests/ProcessSafetyRulesTests`, once with `-only-testing:SpotlessMacTests/MemoryVerdictTests`.
Expected: build failure, `cannot find 'ProcessSafetyRules' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Memory/ProcessSafetyRules.swift`:

```swift
import Darwin
import Foundation

enum QuitDecision: Sendable, Equatable {
    case allowed
    case denied(String)
}

/// Gate for quitting applications — the memory counterpart of `SafetyRules`.
enum ProcessSafetyRules {
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "Finder", "Dock", "SystemUIServer", "ControlCenter",
    ]
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.loginwindow",
    ]

    static func canQuit(
        _ group: AppMemoryGroup,
        runningApps: [RunningAppInfo],
        currentUID: uid_t,
        ownBundlePath: String,
        ownPID: pid_t
    ) -> QuitDecision {
        switch group.kind {
        case .system: return .denied("Системные процессы нельзя завершать из SpotlessMac.")
        case .other: return .denied("Это процессы командной строки — завершите их там, где запускали.")
        case .userApp: break
        }
        guard let bundlePath = group.bundlePath else { return .denied("Не найдено приложение.") }
        if bundlePath == ownBundlePath || group.processes.contains(where: { $0.pid == ownPID }) {
            return .denied("Это сам SpotlessMac.")
        }
        if group.processes.contains(where: { $0.uid != currentUID }) {
            return .denied("Часть процессов запущена другим пользователем или системой.")
        }
        if group.processes.contains(where: { protectedNames.contains($0.name) })
            || runningApps.contains(where: { $0.bundleIdentifier.map(protectedBundleIDs.contains) == true }) {
            return .denied("Это системный компонент macOS.")
        }
        if runningApps.isEmpty {
            return .denied("Приложение не открыто — работают только его фоновые службы.")
        }
        let quittable = runningApps.contains {
            $0.policy == .regular || ($0.policy == .accessory && !BundlePath.isSystem(bundlePath))
        }
        if !quittable {
            return .denied("Это фоновая служба, а не обычное приложение.")
        }
        return .allowed
    }
}
```

`SpotlessMac/Memory/MemoryVerdict.swift`:

```swift
import Foundation

/// One rule-generated sentence summarizing memory state.
enum MemoryVerdict {
    static func text(system: SystemMemorySnapshot, groups: [AppMemoryGroup]) -> String {
        let top = groups.filter { $0.kind == .userApp }.prefix(2)
            .map { "\($0.displayName) (\(format($0.footprint)))" }
            .joined(separator: ", ")
        let holders = top.isEmpty ? "" : " Больше всего держат: \(top)."
        let heavySwap = system.physical > 0 && system.swapUsed * 4 > system.physical

        if system.pressure == .critical || heavySwap {
            return "Своп \(format(system.swapUsed)) — система активно вытесняет память.\(holders)"
        }
        if system.pressure == .warning {
            return "Память под нагрузкой.\(holders)"
        }
        return "Памяти достаточно."
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
```

```bash
python3 scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/ProcessSafetyRules.swift SpotlessMac/Memory/MemoryVerdict.swift
```

- [ ] **Step 4: Run the tests and verify they pass**

Both classes report `** TEST SUCCEEDED **` (8 + 5 tests).

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Memory SpotlessMacTests/ProcessSafetyRulesTests.swift SpotlessMacTests/MemoryVerdictTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): add quit safety rules and memory verdict" -- SpotlessMac/Memory SpotlessMacTests/ProcessSafetyRulesTests.swift SpotlessMacTests/MemoryVerdictTests.swift SpotlessMac.xcodeproj/project.pbxproj
```

---

### Task 4: MemoryViewModel (polling loop, history, stable order, quit flow)

**Files:**
- Create: `SpotlessMac/Memory/MemoryViewModel.swift` (contains `MemoryHistoryPoint`, `AppTerminator`, `QuitState`, `MemoryViewModel`)
- Test: `SpotlessMacTests/MemoryViewModelTests.swift`

**Interfaces:**
- Consumes: `MemoryMonitor`, `ProcessSafetyRules`, models.
- Produces (used by the UI in Tasks 5–6):
  - `struct MemoryHistoryPoint: Identifiable` (date, swapUsed, compressed, pressure)
  - `struct AppTerminator: Sendable` (`terminate`, `forceTerminate`, `isAnyRunning`, all `@MainActor @Sendable ([pid_t]) -> …`; `static let live`)
  - `enum QuitState: Equatable { idle, confirm(AppMemoryGroup, QuitDecision), quitting(AppMemoryGroup), stillRunning(AppMemoryGroup), finished(String) }`
  - `@Observable @MainActor final class MemoryViewModel`:
    - `init(sample: Sample? = nil, terminator: AppTerminator = .live, interval: Duration = .seconds(2), quitGracePeriod: Duration = .seconds(5), ownBundlePath: String = Bundle.main.bundlePath)`
    - read-only `latest: MemorySample?`, `history: [MemoryHistoryPoint]`, `displayedGroups: [AppMemoryGroup]`, `quitState: QuitState`, `isRunning: Bool`
    - read/write `expandedGroupIDs: Set<String>`
    - `start()`, `stop()`, `resortNow()`, `apply(_:)`, `static order(_:previous:resort:)`, `requestQuit(_:)`, `confirmQuit() async`, `confirmForceQuit()`, `dismissQuit()`
    - `static let historyLimit = 150`, `static let resortInterval: TimeInterval = 10`

- [ ] **Step 1: Write the failing tests**

`SpotlessMacTests/MemoryViewModelTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

private actor SampleSource {
    private(set) var calls = 0
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    func next() async -> MemorySample {
        calls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        try? await Task.sleep(for: .milliseconds(5))
        inFlight -= 1
        return MemoryFixtures.sample(at: Date())
    }
}

@MainActor
private final class TerminatorSpy {
    var terminated: [pid_t] = []
    var forced: [pid_t] = []
    var stillRunning = false

    var terminator: AppTerminator {
        AppTerminator(
            terminate: { self.terminated += $0 },
            forceTerminate: { self.forced += $0 },
            isAnyRunning: { _ in self.stillRunning }
        )
    }
}

@MainActor
final class MemoryViewModelTests: XCTestCase {
    private typealias F = MemoryFixtures
    private let slackPath = "/Applications/Slack.app"

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testHistoryIsCapped() {
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) })
        let start = Date()
        for index in 0..<160 {
            viewModel.apply(F.sample(at: start.addingTimeInterval(Double(index)), swapUsed: UInt64(index)))
        }
        XCTAssertEqual(viewModel.history.count, MemoryViewModel.historyLimit)
        XCTAssertEqual(viewModel.history.first?.swapUsed, 10)
        XCTAssertEqual(viewModel.history.last?.swapUsed, 159)
    }

    func testOrderKeepsPreviousPositionsUntilResort() {
        let a = F.userGroup("/Applications/A.app", processes: [F.process(1, footprint: 100)])
        let b = F.userGroup("/Applications/B.app", processes: [F.process(2, footprint: 200)])
        let c = F.userGroup("/Applications/C.app", processes: [F.process(3, footprint: 50)])

        let kept = MemoryViewModel.order([b, c], previous: [a, c, b], resort: false)
        XCTAssertEqual(kept.map(\.id), [c.id, b.id], "known groups keep order, vanished ones drop")

        let appended = MemoryViewModel.order([b, a, c], previous: [a, b], resort: false)
        XCTAssertEqual(appended.map(\.id), [a.id, b.id, c.id], "new groups are appended")

        XCTAssertEqual(MemoryViewModel.order([b, a], previous: [a, b], resort: true).map(\.id), [b.id, a.id])
    }

    func testApplyResortsAtMostEveryTenSeconds() {
        let small = F.userGroup("/Applications/A.app", processes: [F.process(1, footprint: 100)])
        let big = F.userGroup("/Applications/B.app", processes: [F.process(2, footprint: 200)])
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) })
        let start = Date()

        viewModel.apply(F.sample(at: start, groups: [small, big]))
        viewModel.apply(F.sample(at: start.addingTimeInterval(2), groups: [big, small]))
        XCTAssertEqual(viewModel.displayedGroups.map(\.id), [small.id, big.id])

        viewModel.apply(F.sample(at: start.addingTimeInterval(11), groups: [big, small]))
        XCTAssertEqual(viewModel.displayedGroups.map(\.id), [big.id, small.id])
    }

    func testStartSamplesAndStopHalts() async {
        let source = SampleSource()
        let viewModel = MemoryViewModel(sample: { await source.next() }, interval: .milliseconds(10))
        viewModel.start()
        await waitUntil { await source.calls >= 3 }
        viewModel.stop()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertNotNil(viewModel.latest)

        try? await Task.sleep(for: .milliseconds(30))
        let afterStop = await source.calls
        try? await Task.sleep(for: .milliseconds(60))
        let later = await source.calls
        XCTAssertEqual(afterStop, later)
    }

    func testRestartDoesNotRunTwoLoops() async {
        let source = SampleSource()
        let viewModel = MemoryViewModel(sample: { await source.next() }, interval: .milliseconds(1))
        viewModel.start()
        viewModel.start()
        viewModel.start()
        await waitUntil { await source.calls >= 10 }
        viewModel.stop()
        let maxInFlight = await source.maxInFlight
        XCTAssertEqual(maxInFlight, 1)
    }

    func testAllowedQuitTerminatesAndFinishes() async {
        let spy = TerminatorSpy()
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator,
                                        quitGracePeriod: .milliseconds(100), ownBundlePath: "/nowhere")
        let slack = F.userGroup(slackPath, processes: [F.process(42, uid: getuid())])
        viewModel.apply(F.sample(at: Date(), groups: [slack], runningApps: [F.app(42, slackPath)]))

        viewModel.requestQuit(slack)
        XCTAssertEqual(viewModel.quitState, .confirm(slack, .allowed))
        await viewModel.confirmQuit()
        XCTAssertEqual(spy.terminated, [42])
        guard case .finished = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
    }

    func testUnresponsiveAppOffersForceQuit() async {
        let spy = TerminatorSpy()
        spy.stillRunning = true
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator,
                                        quitGracePeriod: .milliseconds(100), ownBundlePath: "/nowhere")
        let slack = F.userGroup(slackPath, processes: [F.process(42, uid: getuid())])
        viewModel.apply(F.sample(at: Date(), groups: [slack], runningApps: [F.app(42, slackPath)]))

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))
        XCTAssertTrue(spy.forced.isEmpty)

        viewModel.confirmForceQuit()
        XCTAssertEqual(spy.forced, [42])
        guard case .finished = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
    }

    func testDeniedQuitNeverTerminates() async {
        let spy = TerminatorSpy()
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator, ownBundlePath: "/nowhere")
        let system = AppMemoryGroup(id: "system", displayName: "Система", kind: .system, bundlePath: nil,
                                    processes: [F.process(1, uid: 0)])
        viewModel.apply(F.sample(at: Date(), groups: [system]))

        viewModel.requestQuit(system)
        guard case .confirm(_, .denied) = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
        await viewModel.confirmQuit()
        XCTAssertTrue(spy.terminated.isEmpty)
        viewModel.dismissQuit()
        XCTAssertEqual(viewModel.quitState, .idle)
    }
}
```

```bash
python3 scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/MemoryViewModelTests.swift
```

- [ ] **Step 2: Run the tests and verify they fail**

Run the test command with `-only-testing:SpotlessMacTests/MemoryViewModelTests`.
Expected: build failure, `cannot find 'MemoryViewModel' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Memory/MemoryViewModel.swift`:

```swift
import AppKit
import Foundation
import Observation

struct MemoryHistoryPoint: Sendable, Equatable, Identifiable {
    let date: Date
    let swapUsed: UInt64
    let compressed: UInt64
    let pressure: MemoryPressure
    var id: Date { date }
}

/// Quits applications through `NSRunningApplication` only — never `kill(2)`.
struct AppTerminator: Sendable {
    var terminate: @MainActor @Sendable ([pid_t]) -> Void
    var forceTerminate: @MainActor @Sendable ([pid_t]) -> Void
    var isAnyRunning: @MainActor @Sendable ([pid_t]) -> Bool

    static let live = AppTerminator(
        terminate: { pids in pids.forEach { _ = NSRunningApplication(processIdentifier: $0)?.terminate() } },
        forceTerminate: { pids in pids.forEach { _ = NSRunningApplication(processIdentifier: $0)?.forceTerminate() } },
        isAnyRunning: { pids in
            pids.contains { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
        }
    )
}

enum QuitState: Equatable {
    case idle
    case confirm(AppMemoryGroup, QuitDecision)
    case quitting(AppMemoryGroup)
    case stillRunning(AppMemoryGroup)
    case finished(String)
}

@Observable @MainActor
final class MemoryViewModel {
    typealias Sample = @Sendable () async -> MemorySample

    static let historyLimit = 150
    static let resortInterval: TimeInterval = 10

    private(set) var latest: MemorySample?
    private(set) var history: [MemoryHistoryPoint] = []
    /// Groups in display order; re-sorted at most every `resortInterval`.
    private(set) var displayedGroups: [AppMemoryGroup] = []
    var expandedGroupIDs: Set<String> = []
    private(set) var quitState: QuitState = .idle

    private let sample: Sample
    private let terminator: AppTerminator
    private let interval: Duration
    private let quitGracePeriod: Duration
    private let ownBundlePath: String
    private var loop: Task<Void, Never>?
    private var lastSort: Date?

    init(
        sample: Sample? = nil,
        terminator: AppTerminator = .live,
        interval: Duration = .seconds(2),
        quitGracePeriod: Duration = .seconds(5),
        ownBundlePath: String = Bundle.main.bundlePath
    ) {
        let monitor = MemoryMonitor()
        self.sample = sample ?? { await monitor.sample() }
        self.terminator = terminator
        self.interval = interval
        self.quitGracePeriod = quitGracePeriod
        self.ownBundlePath = ownBundlePath
    }

    var isRunning: Bool { loop != nil }

    func start() {
        loop?.cancel()
        let sample = sample
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let next = await sample()
                guard !Task.isCancelled else { return }
                self?.apply(next)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func resortNow() {
        guard let latest else { return }
        displayedGroups = Self.order(latest.groups, previous: displayedGroups, resort: true)
        lastSort = latest.date
    }

    func apply(_ next: MemorySample) {
        latest = next
        history.append(MemoryHistoryPoint(date: next.date, swapUsed: next.system.swapUsed,
                                          compressed: next.system.compressed, pressure: next.system.pressure))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        let resort = lastSort.map { next.date.timeIntervalSince($0) >= Self.resortInterval } ?? true
        displayedGroups = Self.order(next.groups, previous: displayedGroups, resort: resort)
        if resort { lastSort = next.date }
    }

    /// Keeps the previous order for known groups (so expanded rows don't jump),
    /// appends new ones, drops vanished ones. `resort` uses the fresh order.
    static func order(_ groups: [AppMemoryGroup], previous: [AppMemoryGroup], resort: Bool) -> [AppMemoryGroup] {
        if resort || previous.isEmpty { return groups }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = previous.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + groups.filter { !keptIDs.contains($0.id) }
    }

    // MARK: Quit flow

    func requestQuit(_ group: AppMemoryGroup) {
        let apps = latest?.runningApps(in: group) ?? []
        let decision = ProcessSafetyRules.canQuit(
            group, runningApps: apps, currentUID: getuid(),
            ownBundlePath: ownBundlePath, ownPID: getpid()
        )
        quitState = .confirm(group, decision)
    }

    func confirmQuit() async {
        guard case .confirm(let group, .allowed) = quitState else { return }
        let pids = (latest?.runningApps(in: group) ?? []).map(\.pid)
        quitState = .quitting(group)
        terminator.terminate(pids)

        let step = Duration.milliseconds(250)
        var waited = Duration.zero
        while waited < quitGracePeriod {
            if !terminator.isAnyRunning(pids) {
                quitState = .finished("\(group.displayName) завершено.")
                return
            }
            try? await Task.sleep(for: step)
            waited += step
        }
        quitState = terminator.isAnyRunning(pids) ? .stillRunning(group) : .finished("\(group.displayName) завершено.")
    }

    func confirmForceQuit() {
        guard case .stillRunning(let group) = quitState else { return }
        let pids = (latest?.runningApps(in: group) ?? []).map(\.pid)
        terminator.forceTerminate(pids)
        quitState = .finished("\(group.displayName) завершено принудительно.")
    }

    func dismissQuit() {
        quitState = .idle
    }
}
```

Design notes for the implementer:
- The loop is sequential: await the sample, apply it, then sleep. A slow sample therefore delays the next tick instead of overlapping with it (spec: "no overlapping samples"). `start()` cancels any previous loop first. `testRestartDoesNotRunTwoLoops` checks that at most one sample is in flight.
- `confirmQuit` polls `isAnyRunning` every 250 ms up to `quitGracePeriod` (5 s in production). It never escalates to force on its own, so the user must confirm in the `.stillRunning` state.

```bash
python3 scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/MemoryViewModel.swift
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: `** TEST SUCCEEDED **`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Memory SpotlessMacTests/MemoryViewModelTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): add memory view model with live polling and quit flow" -- SpotlessMac/Memory SpotlessMacTests/MemoryViewModelTests.swift SpotlessMac.xcodeproj/project.pbxproj
```

---

### Task 5: «Память» section UI and navigation

**Files:**
- Create: `SpotlessMac/App/MemoryView.swift`
- Create: `SpotlessMac/App/MemoryQuitSheet.swift`
- Modify: `SpotlessMac/App/ContentView.swift` (`AppTab` enum at the top; `@State` view models; `tabContent` switch)
- Modify: `SpotlessMac/App/CareRailView.swift` (`icon` and `shortLabel` switches)

**Interfaces:**
- Consumes: `MemoryViewModel`, `MemoryVerdict`, `MemoryPressure`, `Theme`.
- Produces: `AppTab.memory`, `MemoryView(viewModel:)`, `static MemoryView.color(for:)` and `static MemoryView.label(for:)` (the latter is reused by the dashboard in Task 6).

This task is UI glue covered by the earlier tasks' tests. Its gate is a clean build plus a manual check.

- [ ] **Step 1: Add the tab**

In `SpotlessMac/App/ContentView.swift`, change the `AppTab` enum:

```swift
enum AppTab: String, CaseIterable {
    case care = "Уход"
    case cleaning = "Чистка"
    case uninstall = "Программы"
    case diskUsage = "Диск"
    case memory = "Память"
    case docker = "Docker"
    case settings = "Настройки"

    static let mainTabs: [AppTab] = [.care, .cleaning, .uninstall, .diskUsage, .memory, .docker]
```

(The rest of the enum, `launchTab(from:)`, stays unchanged.)

In `ContentView`, add the view model next to `dockerViewModel`:

```swift
    @State private var memoryViewModel = MemoryViewModel()
```

In `tabContent`, add a case after `.diskUsage`:

```swift
        case .memory:
            MemoryView(viewModel: memoryViewModel)
```

In `SpotlessMac/App/CareRailView.swift`, add to `icon`:

```swift
        case .memory: return "memorychip"
```

and to `shortLabel`:

```swift
        case .memory: return "Память"
```

- [ ] **Step 2: Create the views**

`SpotlessMac/App/MemoryView.swift`:

```swift
import AppKit
import Charts
import SwiftUI

struct MemoryView: View {
    var viewModel: MemoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let sample = viewModel.latest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(sample.system)
                        historyChart
                        Text(MemoryVerdict.text(system: sample.system, groups: sample.groups))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        sources(total: sample.system.physical)
                    }
                    .padding(24)
                }
            } else {
                ProgressView("Собираем данные о памяти…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.dashboardBackground.opacity(0.38))
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: Binding(
            get: { viewModel.quitState != .idle },
            set: { if !$0 { viewModel.dismissQuit() } }
        )) {
            MemoryQuitSheet(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.accentGradient)
                Image(systemName: "memorychip")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Память").font(.title2.bold())
                Text("Что держит оперативную память и своп")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.resortNow()
            } label: {
                Label("Пересортировать", systemImage: "arrow.up.arrow.down")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Summary

    private func summary(_ system: SystemMemorySnapshot) -> some View {
        HStack(spacing: 10) {
            pressureTile(system.pressure)
            tile("Используется", MemoryVerdict.format(system.used),
                 detail: "из \(MemoryVerdict.format(system.physical))")
            tile("Сжато", MemoryVerdict.format(system.compressed), detail: nil)
            tile("Своп", MemoryVerdict.format(system.swapUsed),
                 detail: system.swapTotal > 0 ? "из \(MemoryVerdict.format(system.swapTotal))" : nil)
            tile("Кэш файлов", MemoryVerdict.format(system.cachedFiles), detail: "освобождается сам")
        }
    }

    private func pressureTile(_ pressure: MemoryPressure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Давление").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Circle().fill(Self.color(for: pressure)).frame(width: 10, height: 10)
                Text(Self.label(for: pressure)).font(.system(size: 17, weight: .bold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private func tile(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    static func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return Theme.healthGreen
        case .warning: return Theme.warningOrange
        case .critical: return Theme.destructiveEnd
        case .unknown: return Theme.textTertiary
        }
    }

    static func label(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: return "Норма"
        case .warning: return "Высокое"
        case .critical: return "Критическое"
        case .unknown: return "—"
        }
    }

    // MARK: History

    private var historyChart: some View {
        Chart(viewModel.history) { point in
            LineMark(x: .value("Время", point.date), y: .value("ГБ", Self.gigabytes(point.swapUsed)),
                     series: .value("Метрика", "Своп"))
                .foregroundStyle(by: .value("Метрика", "Своп"))
            LineMark(x: .value("Время", point.date), y: .value("ГБ", Self.gigabytes(point.compressed)),
                     series: .value("Метрика", "Сжато"))
                .foregroundStyle(by: .value("Метрика", "Сжато"))
            RuleMark(x: .value("Время", point.date))
                .foregroundStyle(Self.color(for: point.pressure).opacity(0.08))
        }
        .chartForegroundStyleScale(["Своп": Theme.accentGradientStart, "Сжато": Theme.warningOrange])
        .chartYAxisLabel("ГБ")
        .frame(height: 120)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private static func gigabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    // MARK: Sources

    private func sources(total: UInt64) -> some View {
        let apps = viewModel.displayedGroups.filter { $0.kind == .userApp }
        let rest = viewModel.displayedGroups.filter { $0.kind != .userApp }
        return VStack(alignment: .leading, spacing: 6) {
            Text("ИСТОЧНИКИ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(apps) { group in row(group, total: total) }
            if !rest.isEmpty {
                Text("КОМАНДНАЯ СТРОКА И СИСТЕМА")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 10)
                ForEach(rest) { group in row(group, total: total) }
            }
        }
    }

    private func row(_ group: AppMemoryGroup, total: UInt64) -> some View {
        let expanded = viewModel.expandedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if expanded { viewModel.expandedGroupIDs.remove(group.id) } else { viewModel.expandedGroupIDs.insert(group.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                icon(for: group).frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.displayName).font(.system(size: 13, weight: .semibold))
                        Text("\(group.processes.count) проц.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        if group.hasPartialData {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .help("Нужны права администратора для точных данных")
                        }
                    }
                    ProgressView(value: total > 0 ? min(1, Double(group.footprint) / Double(total)) : 0)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(MemoryVerdict.format(group.footprint)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    Text("вытеснено ≈ \(MemoryVerdict.format(group.pushedOut))")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .frame(width: 150, alignment: .trailing)

                if group.kind == .userApp {
                    Button("Завершить") { viewModel.requestQuit(group) }
                        .controlSize(.small)
                } else {
                    Color.clear.frame(width: 72, height: 1)
                }
            }
            if expanded {
                ForEach(group.processes.prefix(40), id: \.pid) { process in
                    HStack {
                        Text(process.name).font(.system(size: 11.5)).lineLimit(1)
                        Text("PID \(process.pid)").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(process.isPartial ? "нет доступа" : MemoryVerdict.format(process.footprint))
                            .font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(process.isPartial ? Theme.textTertiary : Theme.textPrimary)
                    }
                    .padding(.leading, 56)
                }
                if group.processes.count > 40 {
                    Text("и ещё \(group.processes.count - 40)…")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.leading, 56)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
    }

    @ViewBuilder
    private func icon(for group: AppMemoryGroup) -> some View {
        if let path = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: group.kind == .system ? "gearshape.2" : "terminal")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
```

`SpotlessMac/App/MemoryQuitSheet.swift`:

```swift
import SwiftUI

struct MemoryQuitSheet: View {
    var viewModel: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch viewModel.quitState {
            case .idle:
                EmptyView()
            case .confirm(let group, let decision):
                title("Завершить \(group.displayName)?")
                switch decision {
                case .allowed:
                    Text("Будет закрыто приложение целиком (\(group.processes.count) проц.). Ожидается освободить примерно \(MemoryVerdict.format(group.footprint)). Приложение может попросить сохранить документы.")
                        .fixedSize(horizontal: false, vertical: true)
                    buttons(primary: "Завершить") { Task { await viewModel.confirmQuit() } }
                case .denied(let reason):
                    Text(reason).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("Понятно") { viewModel.dismissQuit() }.keyboardShortcut(.defaultAction) }
                }
            case .quitting(let group):
                title("Завершаем \(group.displayName)…")
                ProgressView().frame(maxWidth: .infinity)
            case .stillRunning(let group):
                title("\(group.displayName) не закрылось")
                Text("Приложение не ответило за 5 секунд. Принудительное завершение закроет его сразу — несохранённые данные будут потеряны.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(primary: "Завершить принудительно", role: .destructive) { viewModel.confirmForceQuit() }
            case .finished(let message):
                title(message)
                Text("Изменения появятся в списке через пару секунд.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Готово") { viewModel.dismissQuit() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title3.bold())
    }

    private func buttons(primary: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Отмена") { viewModel.dismissQuit() }.keyboardShortcut(.cancelAction)
            Button(primary, role: role, action: action).keyboardShortcut(.defaultAction)
        }
    }
}
```

```bash
python3 scripts/xcodeproj-add.py app App SpotlessMac/App/MemoryView.swift SpotlessMac/App/MemoryQuitSheet.swift
```

- [ ] **Step 3: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`. If a `switch` on `AppTab` elsewhere fails as non-exhaustive, add the `.memory` case there with the same pattern (as of writing, only `ContentView.tabContent` and `CareRailView` switch on it).

- [ ] **Step 4: Manual check**

```bash
./scripts/install-local-debug.sh   # or: open build/DerivedData/Build/Products/Debug/SpotlessMac.app
```

Open «Память» and check:
- The tiles match Activity Monitor → Memory within a few percent: «Используется» ≈ «Используемая память», «Сжато», «Своп».
- Values update about every 2 s, and the chart grows.
- Chrome/Slack/Docker each appear as one row. Expanding a row lists its processes, and the row does not jump for 10 s.
- «Завершить» on a harmless app (e.g. TextEdit with no documents) shows the confirmation sheet, then closes the app.
- «Завершить» on Finder shows a denial reason and no quit button.
- Switching to another tab stops sampling. Activity Monitor's CPU for SpotlessMac drops to ~0.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/App/MemoryView.swift SpotlessMac/App/MemoryQuitSheet.swift SpotlessMac/App/ContentView.swift SpotlessMac/App/CareRailView.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): add Memory section with live sources and quit sheet" -- SpotlessMac/App/MemoryView.swift SpotlessMac/App/MemoryQuitSheet.swift SpotlessMac/App/ContentView.swift SpotlessMac/App/CareRailView.swift SpotlessMac.xcodeproj/project.pbxproj
```

> `ContentView.swift` and `CareRailView.swift` already carry unrelated uncommitted edits. Committing them includes those edits. Report it to the coordinator instead of splitting hunks.

---

### Task 6: Care dashboard memory card, remove MemoryStatsService

**Files:**
- Modify: `SpotlessMac/App/CareDashboardView.swift` (the `memoryStats` state at line ~11, the `.task` at ~32–38, the «Память» `statCard` at ~131–133)
- Delete: `SpotlessMac/ScanEngine/MemoryStatsService.swift` (+ its 4 lines in `project.pbxproj`)

**Interfaces:**
- Consumes: `MemoryMonitor`, `MemorySample`, `MemoryVerdict.format`, `MemoryView.label(for:)`, `AppTab.memory`.
- Produces: nothing new.

- [ ] **Step 1: Replace the state and the loading**

In `CareDashboardView`, replace

```swift
    @State private var memoryStats: MemoryStats?
```

with

```swift
    @State private var memorySample: MemorySample?
```

In `.task`, replace

```swift
            async let mem = MemoryStatsService.current()
            async let disk = DiskSpaceService.overview()
            memoryStats = await mem
            diskOverview = await disk
```

with

```swift
            async let mem = MemoryMonitor().sample()
            async let disk = DiskSpaceService.overview()
            memorySample = await mem
            diskOverview = await disk
```

- [ ] **Step 2: Replace the card**

Replace

```swift
            statCard(iconBackground: Theme.accentGradientStart.opacity(0.12), icon: "bolt.fill",
                     iconColor: Theme.accentGradientStart, title: "Память",
                     subtitle: memoryStats.map { "свободно \($0.formattedFree)" } ?? "…")
```

with

```swift
            Button { selectedTab = .memory } label: {
                statCard(iconBackground: Theme.accentGradientStart.opacity(0.12), icon: "memorychip",
                         iconColor: Theme.accentGradientStart, title: "Память",
                         subtitle: memorySubtitle)
            }
            .buttonStyle(.plain)
            .help("Открыть раздел «Память»")
```

and add this computed property next to `healthScore`:

```swift
    private var memorySubtitle: String {
        guard let sample = memorySample else { return "…" }
        let pressure = MemoryView.label(for: sample.system.pressure).lowercased()
        let header = "Давление: \(pressure) · своп \(MemoryVerdict.format(sample.system.swapUsed))"
        let top = sample.groups.filter { $0.kind == .userApp }.prefix(3)
            .map { "\($0.displayName) — \(MemoryVerdict.format($0.footprint))" }
        return ([header] + top).joined(separator: "\n")
    }
```

- [ ] **Step 3: Delete MemoryStatsService**

```bash
git rm SpotlessMac/ScanEngine/MemoryStatsService.swift
sed -i '' '/MemoryStatsService.swift/d' SpotlessMac.xcodeproj/project.pbxproj
plutil -lint SpotlessMac.xcodeproj/project.pbxproj
grep -rn "MemoryStats\b\|MemoryStatsService" SpotlessMac SpotlessMacTests || echo "no references left"
```

Expected: `OK` and `no references left`.

- [ ] **Step 4: Build and run the full test suite**

Run the build command, then the test command without `-only-testing`.
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`, with all memory tests (35) plus the existing suite.

- [ ] **Step 5: Manual check**

Launch the Debug app. On «Уход», the «Память» card shows pressure, swap and the top 3 apps, and clicking it opens «Память». The numbers agree with the Memory section.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/App/CareDashboardView.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(memory): show memory pressure and top apps on the Care dashboard" -- SpotlessMac/App/CareDashboardView.swift SpotlessMac/ScanEngine/MemoryStatsService.swift SpotlessMac.xcodeproj/project.pbxproj
```
