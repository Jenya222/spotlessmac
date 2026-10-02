import AppKit
import SwiftUI

struct StorageRecoveryView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var sort: StorageRecoverySort = .sizeDescending
    @State private var itemPendingDelete: ScanItem?
    @State private var batchItemsPendingDelete: [ScanItem] = []
    @State private var lastFailure: DeletionFailure?
    @State private var showActivation = false

    private let categoryOrder: [ScanCategory] = [
        .userCaches,
        .developerCaches,
        .logs,
        .oldInstallers,
        .largeFiles,
        .knownAppCaches, .modelCaches, .projectArtifacts, .recordings,
    ]

    private var filteredItems: [ScanItem] {
        StorageRecoveryQuery.filter(viewModel.items, searchText: searchText, sort: sort)
    }

    private var visibleCategories: [ScanCategory] {
        categoryOrder.filter { category in
            filteredItems.contains { $0.category == category }
        }
    }

    private var selectedBytes: Int64 {
        viewModel.selectedItems.reduce(0) { $0 + $1.size }
    }

    private var reviewItemCount: Int {
        viewModel.items.filter { !$0.category.isBatchCleanable }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let staging = viewModel.assistantStaging { assistantBanner(staging) }
            controls
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 620)
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { itemPendingDelete != nil },
                set: { if !$0 { itemPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Переместить в Корзину", role: .destructive) {
                deletePendingItem()
            }
            Button("Отмена", role: .cancel) { itemPendingDelete = nil }
        } message: {
            if let itemPendingDelete {
                Text("\(itemPendingDelete.path.path(percentEncoded: false))\n\(itemPendingDelete.formattedSize) · \(itemPendingDelete.cleanupPolicy.disposition.label)\n\(itemPendingDelete.cleanupReason)")
            }
        }
        .sheet(isPresented: Binding(
            get: { !batchItemsPendingDelete.isEmpty },
            set: { if !$0 { batchItemsPendingDelete = [] } }
        )) {
            BatchDeleteConfirmationSheet(
                items: batchItemsPendingDelete,
                onCancel: { batchItemsPendingDelete = [] },
                onConfirm: {
                    let snapshot = batchItemsPendingDelete
                    batchItemsPendingDelete = []
                    deleteSelectedItems(snapshot)
                }
            )
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
            if let lastFailure { Text(lastFailure.reason) }
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
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.accentGradient)
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("Освобождение места")
                    .font(.title2.bold())
                Text("Безопасные данные выбраны автоматически. Новые кэши, модели и личные файлы удаляются по одному после проверки.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Закрыть") { dismiss() }
        }
        .padding(20)
    }

    private func assistantBanner(_ staging: ScanViewModel.AssistantStaging) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accentGradientStart)
            Text("Выбрано ассистентом: \(staging.count) элементов, \(ByteCountFormatter.string(fromByteCount: staging.bytes, countStyle: .file)). Проверьте список перед удалением.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Сбросить выбор") {
                viewModel.selectNone()
                viewModel.clearAssistantStaging()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.warningBackground)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Label(
                ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file),
                systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(Theme.healthGreenText)
            .font(.callout.weight(.semibold))

            if reviewItemCount > 0 {
                Text("\(reviewItemCount) требуют проверки")
                    .font(.caption)
                    .foregroundStyle(Theme.warningOrange)
            }

            Spacer()

            TextField("Поиск по имени или пути", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)

            Picker("Сортировка", selection: $sort) {
                ForEach(StorageRecoverySort.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.isScanning && viewModel.items.isEmpty {
            ProgressView("Ищем безопасные способы освободить место…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "Нечего очищать" : "Ничего не найдено",
                systemImage: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "В разрешённых папках не найдено подходящих файлов."
                    : "Попробуйте изменить строку поиска.")
            )
        } else {
            List {
                ForEach(visibleCategories) { category in
                    Section {
                        ForEach(items(in: category)) { item in
                            StorageRecoveryRow(
                                item: item,
                                isDestructiveActionDisabled: viewModel.isDeleting || viewModel.isCleaning || viewModel.isScanning,
                                onToggle: { viewModel.toggleSelection(item) },
                                onDelete: { requestDelete(item) },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.path])
                                }
                            )
                        }
                    } header: {
                        categoryHeader(category)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.scan() }
            } label: {
                Label("Сканировать снова", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isScanning || viewModel.isDeleting || viewModel.isCleaning)

            if let scanError = viewModel.scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if let report = viewModel.cleanupReport {
                Text("Перемещено в Корзину: " + ByteCountFormatter.string(fromByteCount: report.trashedBytes, countStyle: .file)).font(.caption)
                    .help(report.measurementDescription + ". Корзина продолжает занимать место.")
            }
            Spacer()

            Button {
                requestDeleteSelectedItems()
            } label: {
                if viewModel.isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Очистить выбранное · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isDeleting || viewModel.isCleaning || viewModel.isScanning)
        }
        .padding(20)
    }

    private func items(in category: ScanCategory) -> [ScanItem] {
        filteredItems.filter { $0.category == category }
    }

    private func categoryHeader(_ category: ScanCategory) -> some View {
        let categoryItems = items(in: category)
        let total = categoryItems.reduce(Int64(0)) { $0 + $1.size }
        return HStack {
            Text(category.displayName)
            if !category.isBatchCleanable {
                Text("ПРОВЕРЬТЕ")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.warningOrange)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                .monospacedDigit()
        }
    }

    private func requestDelete(_ item: ScanItem) {
        guard !viewModel.isDeleting, !viewModel.isCleaning, !viewModel.isScanning else { return }
        if licenseManager.canClean {
            itemPendingDelete = item
        } else {
            showActivation = true
        }
    }

    private func deletePendingItem() {
        guard let item = itemPendingDelete else { return }
        itemPendingDelete = nil
        Task {
            guard licenseManager.canClean else {
                showActivation = true
                return
            }
            lastFailure = await viewModel.deleteSingle(item)
            if lastFailure == nil && !licenseManager.isActivated {
                licenseManager.recordClean()
            }
        }
    }

    private func deleteSelectedItems(_ snapshot: [ScanItem]) {
        Task {
            guard licenseManager.canClean else {
                showActivation = true
                return
            }
            switch await viewModel.delete(items: snapshot) {
            case .completed(let failures):
                if failures.count < snapshot.count && !licenseManager.isActivated {
                    licenseManager.recordClean()
                }
                lastFailure = failures.first
            case .busy:
                if let first = snapshot.first {
                    lastFailure = DeletionFailure(
                        item: first,
                        reason: "Дождитесь завершения текущей очистки."
                    )
                }
            }
        }
    }

    private func requestDeleteSelectedItems() {
        guard licenseManager.canClean else {
            showActivation = true
            return
        }
        let snapshot = viewModel.selectedItems
        guard !snapshot.isEmpty, !viewModel.isDeleting, !viewModel.isCleaning, !viewModel.isScanning else { return }
        batchItemsPendingDelete = snapshot
    }

    private var deleteTitle: String {
        guard let itemPendingDelete else { return "" }
        return "Переместить «\(itemPendingDelete.path.lastPathComponent)» в Корзину?"
    }
}

private struct StorageRecoveryRow: View {
    let item: ScanItem
    let isDestructiveActionDisabled: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if item.category.isBatchCleanable {
                Button(action: onToggle) {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17))
                        .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDestructiveActionDisabled)
                .accessibilityLabel(item.isSelected ? "Исключить из очистки" : "Добавить в очистку")
            } else {
                Image(systemName: icon)
                    .foregroundStyle(Theme.warningOrange)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.path.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let modifiedAt = item.modifiedAt {
                        Text(modifiedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.cleanupPolicy.disposition.label + " · " + item.cleanupReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.path.path(percentEncoded: false))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if item.category == .recordings {
                Button { NSWorkspace.shared.open(item.path) } label: { Image(systemName: "play.circle") }
                    .help("Прослушать запись")
            }
            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Показать в Finder")

            if !item.category.isBatchCleanable && item.cleanupPolicy.canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(isDestructiveActionDisabled)
                .help("Переместить в Корзину")
            }
        }
        .padding(.vertical, 4)
        .help(item.path.path(percentEncoded: false))
    }

    private var icon: String {
        item.category == .oldInstallers ? "shippingbox.fill" : "doc.fill"
    }
}

private struct BatchDeleteConfirmationSheet: View {
    let items: [ScanItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Переместить выбранные данные в Корзину?")
                    .font(.title2.bold())
                Text("Проверьте каждый путь. Будет перемещено \(items.count) объектов на \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)).")
                    .foregroundStyle(.secondary)
            }

            List(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.path.lastPathComponent)
                            .font(.callout.weight(.medium))
                        Text(item.path.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(item.formattedSize)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Переместить в Корзину", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 650, idealWidth: 700, minHeight: 420, idealHeight: 520)
    }
}
