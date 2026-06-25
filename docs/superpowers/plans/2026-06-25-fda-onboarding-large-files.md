# FDA Onboarding + Large Files Scanner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Full Disk Access onboarding (Block A) and a Large Files scanner with disk-usage visualization (Block B) to MacLeaner.

**Architecture:** FDAService detects Full Disk Access via a protected-path probe; ScanEngine.scan() receives FDA status at call time and activates/skips scanners accordingly. ContentView gains three tabs (Clean / Large Files / Disk Usage); each tab has its own view file. Large-file deletion is strictly per-item with a confirmation dialog — no batch selection.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 14+, @Observable, FileManager, Darwin's `access()` syscall for FDA probe.

## Global Constraints

- macOS 14 minimum deployment target
- Swift 6.0 strict concurrency — all cross-actor types must be `Sendable`
- No `FileManager.removeItem` — only `FileManager.trashItem`
- `SafetyRules.isSafe(url:)` must gate every `trashItem` call in `ScanEngine`
- No full-disk traversal — scanners enumerate only paths inside `SafetyRules.allowedRoots`
- `ScanItem.isSelected` must default to `false` for `.largeFiles` items
- `selectAll()` must never select `.largeFiles` items
- Batch `delete()` must never delete `.largeFiles` items (extra defense in depth)
- Build command: `xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO`
- Expected success output contains: `** BUILD SUCCEEDED **`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `MacLeaner/ScanEngine/FDAService.swift` | `FDAStatus` enum + `FDAService.detect()` |
| Create | `MacLeaner/ScanEngine/LogsScanner.swift` | Logs scanner (user always, system if FDA) |
| Create | `MacLeaner/ScanEngine/LargeFilesScanner.swift` | Find files > 1 GB in whitelisted user dirs |
| Create | `MacLeaner/App/FDAOnboardingView.swift` | Onboarding sheet: explanation, status, open settings |
| Create | `MacLeaner/App/LargeFilesView.swift` | Large files tab: list + per-item confirmation delete |
| Create | `MacLeaner/App/DiskUsageView.swift` | Disk usage tab: sorted folder bars |
| Modify | `MacLeaner/Models/ScanCategory.swift` | Add `.largeFiles` case |
| Modify | `MacLeaner/ScanEngine/SafetyRules.swift` | Add ~/Downloads, ~/Movies, ~/Documents, ~/Desktop, ~/Music, ~/Pictures |
| Modify | `MacLeaner/ScanEngine/ScanEngine.swift` | `scan(fdaStatus:)` parameter, register new scanners |
| Modify | `MacLeaner/ViewModels/ScanViewModel.swift` | Add `fdaStatus`, `checkFDA()`, `deleteSingle()`, guard batch ops |
| Modify | `MacLeaner/App/ContentView.swift` | Tab enum, tab switcher, onboarding sheet trigger |

---

### Task 1: Add `.largeFiles` to ScanCategory and expand SafetyRules

**Files:**
- Modify: `MacLeaner/Models/ScanCategory.swift`
- Modify: `MacLeaner/ScanEngine/SafetyRules.swift`

**Interfaces:**
- Produces: `ScanCategory.largeFiles` (used by Tasks 4, 6, 7, 8, 9)
- Produces: expanded `SafetyRules.allowedRoots` with six new user-dir roots (used by Tasks 4, 5)

- [ ] **Step 1: Add `.largeFiles` case to `ScanCategory`**

Replace `MacLeaner/Models/ScanCategory.swift` with:

```swift
import Foundation

enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "user_caches"
    case developerCaches = "developer_caches"
    case logs = "logs"
    case trash = "trash"
    case largeFiles = "large_files"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userCaches: "Пользовательские кеши"
        case .developerCaches: "Dev-кеши"
        case .logs: "Логи"
        case .trash: "Корзина"
        case .largeFiles: "Крупные файлы"
        }
    }
}
```

- [ ] **Step 2: Expand `SafetyRules.allowedRoots`**

Replace the `allowedRoots` computed property in `MacLeaner/ScanEngine/SafetyRules.swift`:

```swift
import Foundation

enum SafetyRules {
    static let allowedRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Caches",   directoryHint: .isDirectory),
            home.appending(path: "Library/Logs",      directoryHint: .isDirectory),
            home.appending(path: "Downloads",         directoryHint: .isDirectory),
            home.appending(path: "Movies",            directoryHint: .isDirectory),
            home.appending(path: "Documents",         directoryHint: .isDirectory),
            home.appending(path: "Desktop",           directoryHint: .isDirectory),
            home.appending(path: "Music",             directoryHint: .isDirectory),
            home.appending(path: "Pictures",          directoryHint: .isDirectory),
            URL(filePath: "/Library/Caches", directoryHint: .isDirectory),
            URL(filePath: "/Library/Logs",   directoryHint: .isDirectory),
        ]
    }()

    static let forbiddenPrefixes: [String] = [
        "/System",
        "/private/var/vm",
        "/dev",
        "/cores",
    ]

    static func isSafe(url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        guard allowedRoots.contains(where: { path.hasPrefix($0.path(percentEncoded: false)) }) else {
            return false
        }
        return !forbiddenPrefixes.contains(where: { path.hasPrefix($0) })
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add MacLeaner/Models/ScanCategory.swift MacLeaner/ScanEngine/SafetyRules.swift
git commit -m "feat: add largeFiles category and expand SafetyRules whitelist"
```

---

### Task 2: FDAService — detect Full Disk Access

**Files:**
- Create: `MacLeaner/ScanEngine/FDAService.swift`

**Interfaces:**
- Produces: `FDAStatus: Sendable` enum with cases `.unknown`, `.granted`, `.denied`
- Produces: `FDAService.detect() -> FDAStatus` — synchronous probe, safe to call from any context

- [ ] **Step 1: Create `FDAService.swift`**

```swift
import Darwin

enum FDAStatus: Sendable {
    case unknown, granted, denied
}

enum FDAService {
    // Probes a TCC-protected path. Returns .granted if readable, .denied otherwise.
    static func detect() -> FDAStatus {
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        return access(path, R_OK) == 0 ? .granted : .denied
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/ScanEngine/FDAService.swift
git commit -m "feat: add FDAService for Full Disk Access detection"
```

---

### Task 3: LogsScanner — user logs always, system logs when FDA granted

**Files:**
- Create: `MacLeaner/ScanEngine/LogsScanner.swift`

**Interfaces:**
- Consumes: `ScanCategory.logs`, `ScanItem`, `FDAStatus` (Task 2)
- Produces: `LogsScanner(fdaGranted: Bool): Scanner`

- [ ] **Step 1: Create `LogsScanner.swift`**

```swift
import Foundation

struct LogsScanner: Scanner {
    let fdaGranted: Bool
    let category: ScanCategory = .logs

    func scan() async throws -> [ScanItem] {
        var results: [ScanItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLogs = home.appending(path: "Library/Logs", directoryHint: .isDirectory)
        results += try scanDir(userLogs)
        if fdaGranted {
            let systemLogs = URL(filePath: "/Library/Logs", directoryHint: .isDirectory)
            results += try scanDir(systemLogs)
        }
        return results.sorted { $0.size > $1.size }
    }

    private func scanDir(_ url: URL) throws -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var items: [ScanItem] = []
        for entry in entries {
            let size = try recursiveSize(entry)
            if size > 0 {
                items.append(ScanItem(path: entry, size: size, category: .logs))
            }
        }
        return items
    }

    private func recursiveSize(_ url: URL) throws -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let rv = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let rv = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv.isRegularFile == true {
                total += Int64(rv.fileSize ?? 0)
            }
        }
        return total
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/ScanEngine/LogsScanner.swift
git commit -m "feat: add LogsScanner (user logs always, /Library/Logs with FDA)"
```

---

### Task 4: LargeFilesScanner — find files >1 GB in user dirs

**Files:**
- Create: `MacLeaner/ScanEngine/LargeFilesScanner.swift`

**Interfaces:**
- Consumes: `ScanCategory.largeFiles` (Task 1), expanded `SafetyRules.allowedRoots` (Task 1)
- Produces: `LargeFilesScanner(): Scanner` — returns `ScanItem` with `isSelected: false`

- [ ] **Step 1: Create `LargeFilesScanner.swift`**

```swift
import Foundation

private let largeFileThreshold: Int64 = 1_073_741_824 // 1 GiB

struct LargeFilesScanner: Scanner {
    let category: ScanCategory = .largeFiles

    func scan() async throws -> [ScanItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL] = [
            home.appending(path: "Downloads",  directoryHint: .isDirectory),
            home.appending(path: "Movies",     directoryHint: .isDirectory),
            home.appending(path: "Documents",  directoryHint: .isDirectory),
            home.appending(path: "Desktop",    directoryHint: .isDirectory),
            home.appending(path: "Music",      directoryHint: .isDirectory),
            home.appending(path: "Pictures",   directoryHint: .isDirectory),
        ]
        var results: [ScanItem] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                let rv = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard rv.isRegularFile == true else { continue }
                let size = Int64(rv.fileSize ?? 0)
                if size >= largeFileThreshold {
                    // isSelected: false — large files are never auto-selected
                    results.append(ScanItem(path: file, size: size, category: .largeFiles, isSelected: false))
                }
            }
        }
        return results.sorted { $0.size > $1.size }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/ScanEngine/LargeFilesScanner.swift
git commit -m "feat: add LargeFilesScanner (files >1 GiB, never auto-selected)"
```

---

### Task 5: Wire new scanners into ScanEngine + FDA parameter

**Files:**
- Modify: `MacLeaner/ScanEngine/ScanEngine.swift:8-18`

**Interfaces:**
- Consumes: `FDAStatus` (Task 2), `LogsScanner` (Task 3), `LargeFilesScanner` (Task 4)
- Produces: `ScanEngine.scan(fdaStatus: FDAStatus) async throws -> [ScanItem]`

- [ ] **Step 1: Update `ScanEngine.swift`**

Replace `ScanEngine.swift` with:

```swift
import Foundation

struct DeletionFailure: Sendable {
    let item: ScanItem
    let reason: String
}

actor ScanEngine {
    func scan(fdaStatus: FDAStatus) async throws -> [ScanItem] {
        let scanners: [any Scanner] = [
            CachesScanner(),
            LogsScanner(fdaGranted: fdaStatus == .granted),
            LargeFilesScanner(),
        ]
        var results: [ScanItem] = []
        for scanner in scanners {
            let items = try await scanner.scan()
            results.append(contentsOf: items)
        }
        return results
    }

    // Non-throwing: per-item failures collected and returned.
    // Only FileManager.trashItem is used — never removeItem.
    // Large files (.largeFiles category) must never reach this method via batch delete;
    // use deleteSingle() in ScanViewModel for them.
    func delete(items: [ScanItem]) async -> [DeletionFailure] {
        var failures: [DeletionFailure] = []
        let fm = FileManager.default
        for item in items where SafetyRules.isSafe(url: item.path) {
            do {
                try fm.trashItem(at: item.path, resultingItemURL: nil)
            } catch {
                failures.append(DeletionFailure(item: item, reason: error.localizedDescription))
            }
        }
        return failures
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/ScanEngine/ScanEngine.swift
git commit -m "feat: ScanEngine.scan() accepts FDAStatus, registers LogsScanner and LargeFilesScanner"
```

---

### Task 6: Update ScanViewModel for FDA state + large-file safety

**Files:**
- Modify: `MacLeaner/ViewModels/ScanViewModel.swift`

**Interfaces:**
- Consumes: `FDAStatus`, `FDAService.detect()` (Task 2), `ScanEngine.scan(fdaStatus:)` (Task 5)
- Produces:
  - `fdaStatus: FDAStatus` (read by onboarding view and content view)
  - `checkFDA() -> Void` (called at launch and from onboarding)
  - `cleanableItems: [ScanItem]` (items excluding `.largeFiles`)
  - `largeFileItems: [ScanItem]` (items where category == `.largeFiles`)
  - `deleteSingle(_ item: ScanItem) async -> DeletionFailure?` (per-item for large files)

- [ ] **Step 1: Replace `ScanViewModel.swift`**

```swift
import Foundation
import Observation

@Observable
@MainActor
final class ScanViewModel {
    var items: [ScanItem] = []
    var isScanning = false
    var isDeleting = false
    var scanError: String?
    var deletionFailures: [DeletionFailure] = []
    var fdaStatus: FDAStatus = .unknown

    private let engine = ScanEngine()

    func checkFDA() {
        fdaStatus = FDAService.detect()
    }

    func scan() async {
        checkFDA()
        isScanning = true
        scanError = nil
        deletionFailures = []
        defer { isScanning = false }
        do {
            items = try await engine.scan(fdaStatus: fdaStatus)
        } catch {
            scanError = error.localizedDescription
        }
    }

    // Batch delete — never touches .largeFiles (defense in depth).
    func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        deletionFailures = []
        let toDelete = selectedItems.filter { $0.category != .largeFiles }
        let failures = await engine.delete(items: toDelete)
        deletionFailures = failures
        let failedIDs = Set(failures.map(\.item.id))
        let successIDs = Set(toDelete.map(\.id)).subtracting(failedIDs)
        items.removeAll { successIDs.contains($0.id) }
    }

    // Per-item delete for large files. Returns failure if trashing failed.
    func deleteSingle(_ item: ScanItem) async -> DeletionFailure? {
        let failures = await engine.delete(items: [item])
        if let failure = failures.first {
            return failure
        }
        items.removeAll { $0.id == item.id }
        return nil
    }

    func toggleSelection(_ item: ScanItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    // Never selects .largeFiles items.
    func selectAll() {
        items.indices.forEach { idx in
            if items[idx].category != .largeFiles {
                items[idx].isSelected = true
            }
        }
    }
    func selectNone() { items.indices.forEach { items[$0].isSelected = false } }

    var cleanableItems: [ScanItem] { items.filter { $0.category != .largeFiles } }
    var largeFileItems: [ScanItem] { items.filter { $0.category == .largeFiles } }
    var selectedItems: [ScanItem] { cleanableItems.filter(\.isSelected) }
    var totalSelectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var hasSelection: Bool { !selectedItems.isEmpty }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/ViewModels/ScanViewModel.swift
git commit -m "feat: ScanViewModel adds fdaStatus, checkFDA, deleteSingle, guards selectAll/delete"
```

---

### Task 7: FDAOnboardingView — onboarding sheet

**Files:**
- Create: `MacLeaner/App/FDAOnboardingView.swift`

**Interfaces:**
- Consumes: `FDAStatus` (Task 2), `FDAService.detect()` (Task 2)
- Produces: `FDAOnboardingView(onDismiss: () -> Void)` — a sheet-compatible view

- [ ] **Step 1: Create `FDAOnboardingView.swift`**

```swift
import SwiftUI

struct FDAOnboardingView: View {
    let onDismiss: () -> Void

    @State private var status: FDAStatus = .unknown

    private let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Полный доступ к диску")
                    .font(.title2.bold())
                Text(
                    "MacLeaner может сканировать системные логи и кеши вне вашей домашней папки. " +
                    "Для этого требуется разрешение «Полный доступ к диску» в Системных настройках.\n\n" +
                    "Без этого разрешения сканирование пользовательских кешей продолжит работать."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            statusBadge

            HStack(spacing: 12) {
                Button("Открыть Системные настройки") {
                    NSWorkspace.shared.open(settingsURL)
                }
                .buttonStyle(.borderedProminent)

                Button("Проверить ещё раз") {
                    status = FDAService.detect()
                }
            }

            Button("Продолжить без полного доступа") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 460)
        .onAppear { status = FDAService.detect() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .unknown:
            Label("Проверяется…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .granted:
            Label("Доступ предоставлен", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Доступ не предоставлен", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/App/FDAOnboardingView.swift
git commit -m "feat: add FDAOnboardingView with status badge and settings deeplink"
```

---

### Task 8: LargeFilesView — per-item delete with confirmation

**Files:**
- Create: `MacLeaner/App/LargeFilesView.swift`

**Interfaces:**
- Consumes: `ScanViewModel.largeFileItems` (Task 6), `ScanViewModel.deleteSingle()` (Task 6)
- Produces: `LargeFilesView(viewModel: ScanViewModel)` — tab content view

- [ ] **Step 1: Create `LargeFilesView.swift`**

```swift
import SwiftUI

struct LargeFilesView: View {
    var viewModel: ScanViewModel

    @State private var itemPendingDelete: ScanItem?
    @State private var lastFailure: DeletionFailure?

    var body: some View {
        Group {
            if viewModel.largeFileItems.isEmpty {
                if viewModel.isScanning {
                    ProgressView("Сканирование…")
                } else {
                    ContentUnavailableView(
                        "Крупных файлов не найдено",
                        systemImage: "archivebox",
                        description: Text("Файлов размером более 1 ГБ не обнаружено")
                    )
                }
            } else {
                List(viewModel.largeFileItems) { item in
                    LargeFileRow(item: item) {
                        itemPendingDelete = item
                    }
                }
                .listStyle(.plain)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { itemPendingDelete != nil },
                set: { if !$0 { itemPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Переместить в Корзину", role: .destructive) {
                guard let item = itemPendingDelete else { return }
                itemPendingDelete = nil
                Task {
                    lastFailure = await viewModel.deleteSingle(item)
                }
            }
            Button("Отмена", role: .cancel) {
                itemPendingDelete = nil
            }
        } message: {
            if let item = itemPendingDelete {
                Text(item.path.path(percentEncoded: false))
            }
        }
        .alert(
            "Не удалось переместить файл",
            isPresented: Binding(
                get: { lastFailure != nil },
                set: { if !$0 { lastFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { lastFailure = nil }
        } message: {
            if let f = lastFailure {
                Text(f.reason)
            }
        }
    }

    private var deleteTitle: String {
        guard let item = itemPendingDelete else { return "" }
        return "Переместить «\(item.path.lastPathComponent)» в Корзину?"
    }
}

private struct LargeFileRow: View {
    let item: ScanItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path.lastPathComponent)
                    .lineLimit(1)
                Text(item.path.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.formattedSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
        }
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/App/LargeFilesView.swift
git commit -m "feat: add LargeFilesView with per-item confirmationDialog delete"
```

---

### Task 9: DiskUsageView — top-level folder visualization

**Files:**
- Create: `MacLeaner/App/DiskUsageView.swift`

**Interfaces:**
- Produces: `DiskUsageView()` — standalone tab view, no viewModel dependency

- [ ] **Step 1: Create `DiskUsageView.swift`**

```swift
import SwiftUI

private struct FolderEntry: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct DiskUsageView: View {
    @State private var entries: [FolderEntry] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Вычисляется размер папок…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Нет данных",
                    systemImage: "externaldrive",
                    description: Text("Нажмите «Обновить» для расчёта размеров")
                )
            } else {
                folderList
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Обновить") { Task { await loadEntries() } }
                    .disabled(isLoading)
            }
        }
        .task { await loadEntries() }
    }

    private var folderList: some View {
        let maxSize = entries.first?.size ?? 1
        return List(entries) { entry in
            FolderBarRow(entry: entry, maxSize: maxSize)
        }
        .listStyle(.plain)
    }

    private func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let topLevel = try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var result: [FolderEntry] = []
        for url in topLevel {
            let size = await Task.detached(priority: .utility) {
                Self.recursiveSize(url)
            }.value
            if size > 0 {
                result.append(FolderEntry(url: url, size: size))
            }
        }
        entries = result.sorted { $0.size > $1.size }
    }

    private static func recursiveSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let rv = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv?.isRegularFile == true {
                total += Int64(rv?.fileSize ?? 0)
            }
        }
        return total
    }
}

private struct FolderBarRow: View {
    let entry: FolderEntry
    let maxSize: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)

            Text(entry.url.lastPathComponent)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                let proportion = CGFloat(entry.size) / CGFloat(maxSize)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, geo.size.width * proportion))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)

            Text(entry.formattedSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MacLeaner/App/DiskUsageView.swift
git commit -m "feat: add DiskUsageView with horizontal bars proportional to folder size"
```

---

### Task 10: ContentView — tab navigation + onboarding sheet trigger

**Files:**
- Modify: `MacLeaner/App/ContentView.swift`

**Interfaces:**
- Consumes: `ScanViewModel.fdaStatus` (Task 6), `FDAOnboardingView` (Task 7), `LargeFilesView` (Task 8), `DiskUsageView` (Task 9)
- Produces: updated `ContentView` with three tabs and first-launch onboarding

- [ ] **Step 1: Replace `ContentView.swift`**

```swift
import SwiftUI

private enum AppTab: String, CaseIterable {
    case clean = "Очистка"
    case largeFiles = "Крупные файлы"
    case diskUsage = "Диск"
}

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var selectedTab: AppTab = .clean
    @AppStorage("hasSeenFDAOnboarding") private var hasSeenFDAOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            tabContent
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            viewModel.checkFDA()
            if !hasSeenFDAOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            FDAOnboardingView {
                hasSeenFDAOnboarding = true
                showOnboarding = false
                viewModel.checkFDA()
            }
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 12) {
            Text("MacLeaner")
                .font(.title2.bold())

            Spacer()

            Picker("Раздел", selection: $selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)

            fdaBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var fdaBadge: some View {
        switch viewModel.fdaStatus {
        case .granted:
            Label("FDA", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied:
            Button {
                showOnboarding = true
            } label: {
                Label("FDA", systemImage: "exclamationmark.shield")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .clean:
            cleanTab
        case .largeFiles:
            LargeFilesView(viewModel: viewModel)
        case .diskUsage:
            DiskUsageView()
        }
    }

    // MARK: - Clean tab (existing scan/delete flow)

    private var cleanTab: some View {
        VStack(spacing: 0) {
            cleanToolbar
            Divider()
            if !viewModel.deletionFailures.isEmpty {
                failureBanner
                Divider()
            }
            if let error = viewModel.scanError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.red.opacity(0.1))
                .foregroundStyle(.red)
                Divider()
            }
            resultsList
            Divider()
            statusBar
        }
    }

    private var cleanToolbar: some View {
        HStack(spacing: 12) {
            if viewModel.hasSelection {
                Text(viewModel.formattedTotalSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.opacity)
            }

            Button("Очистить выбранное") {
                Task { await viewModel.delete() }
            }
            .disabled(!viewModel.hasSelection || viewModel.isDeleting || viewModel.isScanning)

            if viewModel.isScanning || viewModel.isDeleting {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Button("Сканировать") {
                Task { await viewModel.scan() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanning || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.default, value: viewModel.hasSelection)
    }

    private var resultsList: some View {
        List(viewModel.cleanableItems) { item in
            ScanItemRow(item: item) {
                viewModel.toggleSelection(item)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.cleanableItems.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "Нажмите «Сканировать»",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Будут найдены кеши и другие ненужные файлы")
                )
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.cleanableItems.count) элементов")
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.hasSelection {
                Button("Снять выделение") { viewModel.selectNone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            } else if !viewModel.cleanableItems.isEmpty {
                Button("Выбрать все") { viewModel.selectAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(viewModel.deletionFailures.count) файлов не удалось переместить в Корзину",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.bold())
            ForEach(viewModel.deletionFailures, id: \.item.id) { failure in
                HStack(alignment: .top, spacing: 4) {
                    Text("·")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.path.lastPathComponent).bold()
                        Text(failure.reason).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .foregroundStyle(.orange)
    }
}

// MARK: - Row

private struct ScanItemRow: View {
    let item: ScanItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .imageScale(.large)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path.lastPathComponent)
                    .lineLimit(1)
                Text(item.path.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.formattedSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project MacLeaner.xcodeproj -scheme MacLeaner \
  -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Final integration smoke test**

Open the app (`open MacLeaner.xcodeproj`, build and run in Xcode) and verify:

1. On first launch, the FDA onboarding sheet appears automatically.
2. "Открыть Системные настройки" opens Privacy & Security → Full Disk Access.
3. "Проверить ещё раз" re-evaluates FDA status (badge updates).
4. "Продолжить без полного доступа" closes the sheet.
5. The FDA badge in the toolbar shows the correct state (green checkmark / orange warning).
6. Clicking the orange badge re-opens the onboarding.
7. The segmented tab bar switches between "Очистка", "Крупные файлы", "Диск".
8. Clicking "Сканировать" on the Clean tab runs the scan; if FDA was granted, log entries appear.
9. Large Files tab shows files >1 GB from Downloads/Movies/etc.
10. Each large file has a trash button; tapping it shows a confirmation dialog naming the file; confirming moves it to Trash.
11. "Выбрать все" on the Clean tab does NOT select large file items.
12. Disk tab shows top-level home folders with proportional horizontal bars.
13. Bars are proportional to the largest folder (largest = full width).
14. "Обновить" in the Disk tab toolbar re-scans and refreshes sizes.

- [ ] **Step 4: Commit**

```bash
git add MacLeaner/App/ContentView.swift
git commit -m "feat: add tab navigation (Clean/Large Files/Disk), FDA badge, onboarding sheet trigger"
```

---

## Self-Review

**Spec coverage check:**

| Requirement | Task |
|-------------|------|
| Onboarding screen explains FDA, shown on first launch | Task 7 (view) + Task 10 (trigger) |
| Button opens System Settings → Full Disk Access | Task 7 (`NSWorkspace.shared.open` with deeplink) |
| FDA status determined by protected-path probe | Task 2 (`FDAService.detect()`) |
| Status shown to user | Task 7 (badge in onboarding), Task 10 (badge in toolbar) |
| User caches work without FDA (soft degradation) | `CachesScanner` unchanged; `LogsScanner` degrades gracefully |
| After FDA, system logs (/Library/Logs) scanned | Task 3 (`LogsScanner(fdaGranted: true)`) |
| `LargeFilesScanner` finds files >1 GB | Task 4 |
| Large files NOT auto-selected | Task 4 (`isSelected: false`), Task 6 (`selectAll` guard) |
| Large files deletable only manually, one by one | Task 8 (`confirmationDialog` per item) |
| Batch delete never touches large files | Task 6 (`delete()` filters out `.largeFiles`) |
| Visualization: top-level folders with size bars | Task 9 |
| Bars proportional to largest folder | Task 9 (`proportion = size / maxSize`) |

**Placeholder scan:** None found. All steps contain complete Swift code.

**Type consistency:**
- `FDAStatus` used as `FDAStatus` in Tasks 2, 5, 6, 7, 10 ✓
- `FDAService.detect()` returns `FDAStatus` in Task 2, consumed in Task 6 ✓
- `ScanViewModel.deleteSingle(_ item: ScanItem) async -> DeletionFailure?` in Task 6, consumed in Task 8 ✓
- `ScanViewModel.largeFileItems: [ScanItem]` in Task 6, consumed in Tasks 8, 10 ✓
- `ScanViewModel.cleanableItems: [ScanItem]` in Task 6, consumed in Task 10 ✓
- `LogsScanner(fdaGranted: Bool)` in Task 3, instantiated in Task 5 ✓
- `ScanEngine.scan(fdaStatus: FDAStatus)` in Task 5, called in Task 6 ✓
