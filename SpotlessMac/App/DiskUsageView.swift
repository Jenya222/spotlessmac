import SwiftUI
import AppKit

struct DiskUsageView: View {
    private let viewModel: ScanViewModel
    private let licenseManager: LicenseManager
    private let onTrashed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.askAssistant) private var askAssistant
    @State private var pathStack: [URL]
    @State private var analysis = StorageAnalysisViewModel()
    @State private var selection: Set<String> = []
    @State private var itemsPendingDelete: [ScanItem] = []
    @State private var failureMessage: String?
    @State private var trashedSummary: String?
    @State private var showActivation = false

    init(startingURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents"),
         viewModel: ScanViewModel, licenseManager: LicenseManager, onTrashed: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.licenseManager = licenseManager
        self.onTrashed = onTrashed
        _pathStack = State(initialValue: [startingURL])
    }
    private var current: URL { pathStack.last! }
    private var isBusy: Bool { analysis.isLoading || viewModel.isDeleting || viewModel.isCleaning }
    private var selectedNodes: [StorageNode] {
        analysis.nodes.filter { selection.contains($0.id) && analysis.deletableNodeIDs.contains($0.id) }
    }
    private var selectedBytes: Int64 { selectedNodes.reduce(0) { $0 + $1.measurement.allocatedBytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 600)
        .task(id: current) {
            selection = []; trashedSummary = nil
            await analysis.scan(root: current)
        }
        .onDisappear { analysis.cancel() }
        .sheet(isPresented: Binding(
            get: { !itemsPendingDelete.isEmpty },
            set: { if !$0 { itemsPendingDelete = [] } }
        )) {
            BatchDeleteConfirmationSheet(
                items: itemsPendingDelete,
                onCancel: { itemsPendingDelete = [] },
                onConfirm: {
                    let snapshot = itemsPendingDelete
                    itemsPendingDelete = []
                    trash(snapshot)
                }
            )
        }
        .alert(
            "Не удалось переместить в Корзину",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            if let failureMessage { Text(failureMessage) }
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
            }
        }
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
                Text("Размер на диске. Откройте папку, чтобы увидеть, что занимает место внутри. Отмеченные объекты перемещаются в Корзину после подтверждения.")
                    .font(.callout).foregroundStyle(.secondary)
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
                DiskUsageRow(
                    node: node,
                    isDeletable: analysis.deletableNodeIDs.contains(node.id),
                    isSelected: selection.contains(node.id),
                    isSelectionDisabled: isBusy,
                    onToggle: { toggle(node) },
                    onOpen: {
                        if node.isDirectory && !node.isPackage { pathStack.append(node.url) }
                        else { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                    },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
                    onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in { ask(node, action) } }
                )
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !selectedNodes.isEmpty {
                Text("Выбрано: \(selectedNodes.count) · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Button("Снять выбор") { selection = [] }
                    .buttonStyle(.plainHand).font(.caption).foregroundStyle(Color.accentColor)
                    .disabled(isBusy)
            } else if let error = analysis.errorMessage, !analysis.nodes.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            } else if analysis.isStale {
                Text("Не обновлено — показан предыдущий снимок").font(.caption).foregroundStyle(Theme.warningOrange)
            } else if let trashedSummary {
                Text(trashedSummary).font(.caption).foregroundStyle(.secondary)
                    .help("Корзина продолжает занимать место, пока её не очистить.")
            } else if let date = analysis.sampledAt, !analysis.isLoading {
                Text("Измерено: \(date.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if analysis.isLoading {
                ProgressView().controlSize(.small)
                Button("Остановить") { analysis.cancel() }
            } else {
                Button { Task { await analysis.scan(root: current) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(viewModel.isDeleting)
            }
            Button(action: requestTrash) {
                if viewModel.isDeleting { ProgressView().controlSize(.small) }
                else { Text("Переместить в Корзину") }
            }
            .buttonStyle(.borderedProminentHand)
            .disabled(selectedNodes.isEmpty || isBusy)
        }
        .padding(20)
    }

    private func toggle(_ node: StorageNode) {
        guard !isBusy, analysis.deletableNodeIDs.contains(node.id) else { return }
        if selection.remove(node.id) == nil { selection.insert(node.id) }
    }

    private func ask(_ node: StorageNode, _ action: AskAssistantAction) {
        let focus = AssistantSnapshotBuilder.focus(for: node, deletable: analysis.deletableNodeIDs.contains(node.id))
        dismiss()
        action(focus)
    }

    private func requestTrash() {
        guard licenseManager.canClean else {
            showActivation = true
            return
        }
        guard !isBusy else { return }
        let items = analysis.deletionItems(for: selection)
        guard !items.isEmpty else { return }
        itemsPendingDelete = items
    }

    private func trash(_ snapshot: [ScanItem]) {
        Task {
            guard licenseManager.canClean else {
                showActivation = true
                return
            }
            switch await viewModel.delete(items: snapshot) {
            case .completed(let failures):
                let failedIDs = Set(failures.map(\.item.id))
                let trashed = snapshot.filter { !failedIDs.contains($0.id) }
                if !trashed.isEmpty {
                    if !licenseManager.isActivated { licenseManager.recordClean() }
                    let bytes = trashed.reduce(Int64(0)) { $0 + $1.size }
                    trashedSummary = "Перемещено в Корзину: \(trashed.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                    onTrashed()
                }
                if let first = failures.first {
                    let more = failures.count > 1 ? "\nИ ещё объектов с ошибкой: \(failures.count - 1)." : ""
                    failureMessage = "«\(first.item.path.lastPathComponent)»: \(first.reason)\(more)"
                }
                selection = []
                await analysis.scan(root: current)
            case .busy:
                failureMessage = "Дождитесь завершения текущей очистки."
            }
        }
    }
}

private struct DiskUsageRow: View {
    let node: StorageNode
    let isDeletable: Bool
    let isSelected: Bool
    let isSelectionDisabled: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    var onAsk: (() -> Void)? = nil

    private var isNavigable: Bool { node.isDirectory && !node.isPackage }

    var body: some View {
        HStack(spacing: 12) {
            selectionControl

            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(node.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isNavigable {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plainHand)

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Text((node.measurement.isComplete ? "" : "Не менее ") + ByteCountFormatter.string(fromByteCount: node.measurement.allocatedBytes, countStyle: .file))
                    .font(.callout.monospacedDigit())
                Text("Логически: " + ByteCountFormatter.string(fromByteCount: node.measurement.logicalBytes, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()

            HStack(spacing: 10) {
                if let onAsk { AskAssistantButton(action: onAsk) }
                Button(action: onReveal) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plainHand)
                .foregroundStyle(Theme.textSecondary)
                .help("Показать в Finder")
            }
        }
        .padding(.vertical, 5)
        .help(node.url.path(percentEncoded: false))
        .askAssistantMenu(onAsk)
    }

    @ViewBuilder
    private var selectionControl: some View {
        if isDeletable {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plainHand)
            .disabled(isSelectionDisabled)
            .help(isSelected ? "Не перемещать в Корзину" : "Отметить для перемещения в Корзину")
            .accessibilityLabel(isSelected ? "Исключить из удаления" : "Отметить для удаления")
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 17)
                .help("Отсюда не удаляется: объект вне безопасных папок или очищается в своём разделе. Нажмите «?», чтобы спросить ассистента.")
                .accessibilityLabel("Удаление недоступно")
        }
    }
}
