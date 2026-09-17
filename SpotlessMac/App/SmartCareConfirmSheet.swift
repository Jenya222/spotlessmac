import SwiftUI

struct SmartCareConfirmSheet: View {
    var viewModel: ScanViewModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var eligibleItems: [ScanItem] {
        viewModel.items.filter { $0.category == .userCaches || $0.category == .logs }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Найдено для очистки")
                .font(.title3.bold())

            Text(ByteCountFormatter.string(fromByteCount: viewModel.smartCareTotalBytes, countStyle: .file))
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 8) {
                ForEach(viewModel.smartCareCategoryTotals) { total in
                    HStack {
                        Text(total.category.displayName)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: total.totalBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(Theme.trackBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))

            Text("Файлы для очистки (\(eligibleItems.count))")
                .font(.callout.weight(.semibold))
            List(eligibleItems) { item in
                ScanItemRow(item: item) { viewModel.toggleSelection(item) }
                    .help(item.path.path(percentEncoded: false))
            }
            .frame(height: 220)

            HStack {
                Button("Отмена", action: onCancel)
                Spacer()
                Button("Начать очистку", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.smartCareSelectedItems.isEmpty || viewModel.isCleaning)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
