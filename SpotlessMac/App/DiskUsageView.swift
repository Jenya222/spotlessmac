import SwiftUI
import AppKit

struct DiskUsageView: View {
    private let startingURL: URL
    @State private var pathStack: [URL]
    @State private var entries: [FolderEntry] = []
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var sizeCache: [String: Int64] = [:]

    init(startingURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.startingURL = startingURL
        _pathStack = State(initialValue: [startingURL])
    }

    private var currentDir: URL { pathStack.last ?? startingURL }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button("Обновить") { reload(invalidateCache: true) }
                    .disabled(isLoading)
            }
        }
        .task { if entries.isEmpty { reload() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Вычисляется размер папок…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "Пусто",
                systemImage: "folder",
                description: Text("Папка пуста или недоступна без полного доступа к диску")
            )
        } else {
            folderList
        }
    }

    private var folderList: some View {
        let maxSize = entries.first?.size ?? 1
        return List(entries) { entry in
            DiskEntryRow(
                entry: entry,
                maxSize: maxSize,
                onOpen: entry.isDirectory ? { navigate(into: entry.url) } : nil,
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            )
        }
        .listStyle(.plain)
    }

    // MARK: - Breadcrumb

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button {
                if pathStack.count > 1 { jump(toDepth: pathStack.count - 2) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(pathStack.count <= 1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pathStack.enumerated()), id: \.offset) { index, url in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(index == 0 ? "Домашняя" : url.lastPathComponent) {
                            jump(toDepth: index)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == pathStack.count - 1 ? Color.primary : Color.accentColor)
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Navigation

    private func navigate(into url: URL) {
        pathStack.append(url)
        reload()
    }

    private func jump(toDepth index: Int) {
        guard index >= 0, index < pathStack.count else { return }
        guard index != pathStack.count - 1 else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        reload()
    }

    // MARK: - Loading

    private func reload(invalidateCache: Bool = false) {
        if invalidateCache {
            // Force recompute of the current directory's children on next pass.
            let prefix = currentDir.standardizedFileURL.path(percentEncoded: false)
            sizeCache = sizeCache.filter { !$0.key.hasPrefix(prefix) }
        }
        loadTask?.cancel()
        loadTask = Task { await loadEntries() }
    }

    private func loadEntries() async {
        let dir = currentDir
        isLoading = true
        defer { isLoading = false }

        let cache = sizeCache
        let result = await FolderSizeCalculator.children(of: dir, cache: cache)
        if Task.isCancelled { return }

        for entry in result where entry.isDirectory {
            sizeCache[entry.url.standardizedFileURL.path(percentEncoded: false)] = entry.size
        }
        entries = result.sorted { $0.size > $1.size }
    }
}

private struct DiskEntryRow: View {
    let entry: FolderEntry
    let maxSize: Int64
    let onOpen: (() -> Void)?
    let onReveal: () -> Void

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Показать в Finder", action: onReveal)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)

            Text(entry.name)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            GeometryReader { geo in
                let proportion = maxSize > 0 ? CGFloat(entry.size) / CGFloat(maxSize) : 0
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(entry.isDirectory ? Color.secondary : Color.clear)
        }
        .padding(.vertical, 3)
    }
}
