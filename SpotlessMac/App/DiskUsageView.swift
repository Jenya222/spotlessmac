import SwiftUI
import AppKit

struct DiskUsageView: View {
    @State private var pathStack: [URL]
    @State private var analysis = StorageAnalysisViewModel()
    init(startingURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")) {
        _pathStack = State(initialValue: [startingURL])
    }
    private var current: URL { pathStack.last! }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Назад") { pathStack.removeLast() }.disabled(pathStack.count <= 1)
                Text(current.path(percentEncoded: false)).font(.caption).textSelection(.enabled)
                Spacer()
                if analysis.isLoading { Button("Остановить") { analysis.cancel() } }
                else { Button("Обновить") { Task { await analysis.scan(root: current) } } }
            }.padding(.horizontal)
            if analysis.isLoading { ProgressView("Вычисляем размер на диске…") }
            if let error = analysis.errorMessage { Text(error).foregroundStyle(.red).padding(.horizontal) }
            if analysis.isStale { Text("Не обновлено").font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            List(analysis.nodes) { node in
                HStack {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    Button(node.url.lastPathComponent) {
                        if node.isDirectory && !node.isPackage { pathStack.append(node.url) }
                        else { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                    }.buttonStyle(.plainHand)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text((node.measurement.isComplete ? "" : "Не менее ") + ByteCountFormatter.string(fromByteCount: node.measurement.allocatedBytes, countStyle: .file)).monospacedDigit()
                        Text("Логически: " + ByteCountFormatter.string(fromByteCount: node.measurement.logicalBytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                }.help(node.url.path(percentEncoded: false))
            }
        }
        .task(id: current) { await analysis.scan(root: current) }
        .onDisappear { analysis.cancel() }
    }
}
