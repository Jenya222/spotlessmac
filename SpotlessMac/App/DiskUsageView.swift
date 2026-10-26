import SwiftUI
import AppKit

struct DiskUsageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pathStack: [URL]
    @State private var analysis = StorageAnalysisViewModel()
    init(startingURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")) {
        _pathStack = State(initialValue: [startingURL])
    }
    private var current: URL { pathStack.last! }
    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 560)
        .task(id: current) { await analysis.scan(root: current) }
        .onDisappear { analysis.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.accentGradient)
                Image(systemName: "folder.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(current.lastPathComponent).font(.title2.bold()).lineLimit(1)
                Text("Размер на диске. Откройте папку, чтобы увидеть, что занимает место внутри.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Закрыть") { dismiss() }
        }
        .padding(20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { pathStack.removeLast() } label: { Label("Назад", systemImage: "chevron.left") }
                .disabled(pathStack.count <= 1)
            Text(current.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([current]) } label: { Label("Показать в Finder", systemImage: "folder") }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var results: some View {
        // While loading, nodes still belong to the previously opened folder.
        if analysis.isLoading {
            ProgressView("Вычисляем размер на диске…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = analysis.errorMessage, analysis.nodes.isEmpty {
            ContentUnavailableView("Папку не удалось измерить", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if analysis.nodes.isEmpty {
            ContentUnavailableView("Папка пуста", systemImage: "folder", description: Text("Внутри нет файлов, доступных для измерения."))
        } else {
            List(analysis.nodes) { node in
                HStack {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
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
                }
                .padding(.vertical, 2)
                .help(node.url.path(percentEncoded: false))
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = analysis.errorMessage, !analysis.nodes.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            } else if analysis.isStale {
                Text("Не обновлено — показан предыдущий снимок").font(.caption).foregroundStyle(Theme.warningOrange)
            } else if let date = analysis.sampledAt, !analysis.isLoading {
                Text("Измерено: \(date.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if analysis.isLoading {
                ProgressView().controlSize(.small)
                Button("Остановить") { analysis.cancel() }
            } else {
                Button { Task { await analysis.scan(root: current) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .padding(20)
    }
}
