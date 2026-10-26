import SwiftUI

struct LargeFilesView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager

    @Environment(\.dismiss) private var dismiss
    @State private var itemPendingDelete: ScanItem?
    @State private var lastFailure: DeletionFailure?
    @State private var showActivation = false

    private var totalBytes: Int64 {
        viewModel.largeFileItems.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 560)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.accentGradient)
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("Крупные файлы")
                    .font(.title2.bold())
                Text("Файлы от 500 МБ в разрешённых папках. Каждый файл перемещается в Корзину отдельно, после подтверждения.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Закрыть") { dismiss() }
        }
        .padding(20)
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.largeFileItems.isEmpty {
            if viewModel.isScanning {
                ProgressView("Сканирование…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Крупных файлов не найдено",
                    systemImage: "archivebox",
                    description: Text("Файлов размером от 500 МБ не обнаружено")
                )
            }
        } else {
            List(viewModel.largeFileItems) { item in
                LargeFileRow(
                    item: item,
                    isDeleteDisabled: viewModel.isDeleting || viewModel.isCleaning || viewModel.isScanning
                ) {
                    guard !viewModel.isDeleting, !viewModel.isCleaning, !viewModel.isScanning else { return }
                    if licenseManager.canClean {
                        itemPendingDelete = item
                    } else {
                        showActivation = true
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !viewModel.largeFileItems.isEmpty {
                Text("Файлов: \(viewModel.largeFileItems.count) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let scanError = viewModel.scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            if viewModel.isScanning || viewModel.isDeleting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
    }

    private var deleteTitle: String {
        guard let item = itemPendingDelete else { return "" }
        return "Переместить «\(item.path.lastPathComponent)» в Корзину?"
    }
}

private struct LargeFileRow: View {
    let item: ScanItem
    let isDeleteDisabled: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.path.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(item.path.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plainHand)
            .foregroundStyle(.red.opacity(0.8))
            .disabled(isDeleteDisabled)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(item.path.path(percentEncoded: false))
    }
}
