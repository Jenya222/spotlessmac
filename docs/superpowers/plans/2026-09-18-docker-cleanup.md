# Docker Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated, preview-first Docker cleanup section for stopped containers, unused images, reclaimable old build cache, and dangling volumes.

**Architecture:** A process runner executes Docker without a shell, a `DockerClient` actor owns scanning/classification/deletion, and a main-actor observable view model drives a dedicated SwiftUI tab. All destructive commands target IDs from an immutable preview snapshot; volumes use a second confirmation.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation `Process`, XCTest, Docker CLI/Buildx.

**Spec:** `docs/superpowers/specs/2026-09-18-docker-cleanup-design.md`

## Global Constraints

- macOS 14 minimum; Xcode 16.2; Swift 6 strict concurrency.
- No third-party dependencies.
- Never run a broad Docker prune command.
- Never remove running containers or images referenced by any container.
- Every destructive action uses exact IDs/names from a confirmed immutable snapshot.
- Volumes are never selected automatically and require a second confirmation.
- Existing FileManager cleanup remains Trash-only; the approved Docker exception stays inside `DockerClient`.

---

### Task 1: Docker domain model and scan parser

**Files:**
- Create: `SpotlessMac/Docker/DockerResource.swift`
- Create: `SpotlessMac/Docker/DockerScanParser.swift`
- Create: `SpotlessMacTests/DockerScanParserTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `DockerResource`, `DockerResourceKind`, `DockerRisk`, `DockerAvailability`, `DockerScanSnapshot`.
- Produces: `DockerScanParser.makeSnapshot(containerJSON:imageJSON:volumeJSON:buildCacheJSON:now:) throws -> DockerScanSnapshot`.

- [x] **Step 1: Write failing parser and classification tests** using complete inspect-array fixtures. Assert that running containers and referenced images are absent, dangling images and old reclaimable cache are selected, tagged images/stopped containers are unselected, and volumes are marked critical and unselected.
- [x] **Step 2: Run** `xcodebuild ... -only-testing:SpotlessMacTests/DockerScanParserTests` and verify compilation fails because the Docker types are missing.
- [x] **Step 3: Implement models and parser** with normalized `sha256:` IDs, ISO-8601 dates, byte sizes from numeric inspect fields, and tolerant Buildx JSON-lines parsing.
- [x] **Step 4: Re-run the targeted tests** and require zero failures.
- [x] **Step 5: Commit** `test/feat: add Docker scan classification` with the tests and minimal passing implementation.

### Task 2: Docker command boundary and exact deletion

**Files:**
- Create: `SpotlessMac/Docker/DockerCommandRunner.swift`
- Create: `SpotlessMac/Docker/DockerClient.swift`
- Create: `SpotlessMacTests/DockerClientTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DockerScanParser` and Docker domain types from Task 1.
- Produces: `DockerCommandResult`, `DockerCommandError`, `DockerClient.scan()`, and `DockerClient.delete(_:)`.
- Injected boundary: `typealias RunDockerCommand = @Sendable ([String]) async throws -> DockerCommandResult`.

- [x] **Step 1: Write failing client tests** with an actor-backed fake runner. Assert the exact read command sequence, that empty ID sets skip inspect calls, and that deletion emits only exact resource commands.
- [x] **Step 2: Add negative tests** proving running-container, referenced-image, non-dangling-volume, and non-reclaimable-cache snapshots are rejected before the runner executes.
- [x] **Step 3: Run targeted tests** and verify failure because `DockerClient` does not exist.
- [x] **Step 4: Implement the process runner** with known executable candidates, no shell, captured UTF-8 output, cancellation termination, and stderr-based errors.
- [x] **Step 5: Implement `DockerClient`** with read-only discovery, pinned context/builder identities, per-resource safety revalidation, exact arguments, and per-resource failures.
- [x] **Step 6: Re-run Task 1 and Task 2 tests** and require zero failures.
- [x] **Step 7: Commit** `feat: add safe Docker command client`.

### Task 3: Observable cleanup flow and licensing

**Files:**
- Create: `SpotlessMac/Docker/DockerCleanupViewModel.swift`
- Create: `SpotlessMacTests/DockerCleanupViewModelTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DockerClient.scan()` and `DockerClient.delete(_:)` via injected async closures.
- Produces: `scan()`, `toggle(_:)`, `makeCleanupSnapshot()`, `deleteConfirmed(_:licenseManager:)`, `isScanning`, `isDeleting`, `availability`, `resources`, and `failures`.

- [x] **Step 1: Write failing state-flow tests** asserting default selections, immutable confirmation snapshots, busy rejection, separate volume acknowledgment, success-only trial recording, and rescan after cleanup.
- [x] **Step 2: Run targeted tests** and verify failure because the view model is missing.
- [x] **Step 3: Implement the minimal main-actor view model** with serialized operations and license admission immediately before deletion.
- [x] **Step 4: Re-run targeted tests** and require zero failures.
- [x] **Step 5: Commit** `feat: add Docker cleanup state flow`.

### Task 4: Dedicated Docker SwiftUI section

**Files:**
- Create: `SpotlessMac/App/DockerCleanupView.swift`
- Modify: `SpotlessMac/App/ContentView.swift`
- Modify: `SpotlessMac/App/CareRailView.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DockerCleanupViewModel` and shared `LicenseManager`.
- Produces: `AppTab.docker` and a complete scan/preview/confirmation/results flow.

- [x] **Step 1: Add `.docker` to `AppTab`** and route it to a state-owned `DockerCleanupViewModel`.
- [x] **Step 2: Implement the status UI** for missing CLI, stopped daemon, scanning, empty results, and populated results.
- [x] **Step 3: Implement category rows and totals** with safe defaults, search, explicit reasons, IDs, sizes, and risk labels.
- [x] **Step 4: Implement immutable confirmation sheets** listing all exact targets; require a second typed warning sheet when volumes are included.
- [x] **Step 5: Build Debug** and fix Swift 6/SwiftUI diagnostics without weakening the safety checks.
- [x] **Step 6: Commit** `feat: add Docker cleanup interface`.

### Task 5: Verification and integration

**Files:**
- Modify only files required by review findings.

**Interfaces:**
- Produces a merge-ready `feature/docker-cleanup` branch.

- [x] **Step 1: Run the full XCTest suite** with a fresh DerivedData directory.
- [x] **Step 2: Run universal Release build** with code signing disabled.
- [x] **Step 3: Launch the exact Debug app** and verify a live populated scan, search, immutable preview, and typed volume warning without clicking the destructive confirmation.
- [x] **Step 4: Run `git diff --check` and focused code review** for command injection, running-resource exclusion, confirmation snapshot correctness, volume handling, licensing, and Swift concurrency.
- [x] **Step 5: Fix every P1/P2 finding with a failing regression test first**, then repeat verification.
- [x] **Step 6: Use `superpowers:finishing-a-development-branch`** to integrate the approved result into `main` and remove the owned worktree after merged tests pass.
