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
        let candidateNames = ["Downloads", "Movies", "Documents", "Desktop",
                              "Music", "Pictures", "Library", "Developer", "Sites"]
        let roots = candidateNames
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        var result: [FolderEntry] = []
        await withTaskGroup(of: FolderEntry?.self) { group in
            for url in roots {
                group.addTask(priority: .utility) {
                    let size = Self.recursiveSize(url)
                    return size > 0 ? FolderEntry(url: url, size: size) : nil
                }
            }
            for await entry in group {
                if let entry { result.append(entry) }
            }
        }
        entries = result.sorted { $0.size > $1.size }
    }

    private nonisolated static func recursiveSize(_ url: URL) -> Int64 {
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
