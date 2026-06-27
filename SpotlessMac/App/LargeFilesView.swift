import SwiftUI

struct LargeFilesView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager

    @State private var itemPendingDelete: ScanItem?
    @State private var lastFailure: DeletionFailure?
    @State private var showActivation = false

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
                        if licenseManager.canClean {
                            itemPendingDelete = item
                        } else {
                            showActivation = true
                        }
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
                    if lastFailure == nil && !licenseManager.isActivated {
                        licenseManager.recordClean()
                    }
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
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
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
