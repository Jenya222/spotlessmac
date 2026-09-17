import SwiftUI

struct CleaningProgressView: View {
    var viewModel: ScanViewModel
    @Binding var selectedTab: AppTab

    var body: some View {
        Group {
            if !viewModel.isCleaning && viewModel.cleaningStartedAt == nil {
                ContentUnavailableView(
                    "Нет активной очистки",
                    systemImage: "wand.and.stars",
                    description: Text("Запустите умный уход с вкладки «Уход»")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    checklist
                    resultDetails
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.dashboardBackground)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().stroke(Theme.trackBackground, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: viewModel.cleaningProgressFraction)
                    .stroke(Theme.accentGradientStart, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        Text("\(Int(viewModel.cleaningProgressFraction * 100))")
                            .font(.system(size: 32, weight: .heavy))
                        Text("%").font(.system(size: 15)).foregroundStyle(Theme.textTertiary)
                    }
                    Text("очистка").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: Theme.cleaningRingSize, height: Theme.cleaningRingSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.isCleaning ? "Наводим порядок…" : (viewModel.smartCareOutcome?.displayTitle ?? "Очистка завершена"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(progressCaption)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                if let item = viewModel.currentCleaningItem {
                    Text(item.path.path(percentEncoded: false))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if viewModel.isCleaning {
                    Button("Остановить") { viewModel.stopSmartCare() }
                        .buttonStyle(.bordered)
                        .padding(.top, 6)
                } else {
                    Button("Готово") { selectedTab = .care }
                        .buttonStyle(.bordered)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var progressCaption: String {
        let freed = ByteCountFormatter.string(fromByteCount: viewModel.bytesFreedSoFar, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: viewModel.smartCareTotalBytes, countStyle: .file)
        switch viewModel.smartCareOutcome {
        case .failed:
            return "Не удалось переместить выбранные объекты в Корзину"
        case .partialFailure:
            return "Освобождено \(freed); часть объектов удалить не удалось"
        case .cancelled:
            return "Освобождено \(freed); осталось объектов: \(viewModel.unprocessedSmartCareItems.count)"
        case .succeeded:
            return "Освобождено \(freed)"
        case nil:
            return "Уже освобождено \(freed) из \(total)"
        }
    }

    private var checklist: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.smartCareCategoryTotals) { total in
                stageRow(for: total)
            }
        }
    }

    @ViewBuilder
    private func stageRow(for total: CategoryTotal) -> some View {
        switch viewModel.smartCareCategoryState(for: total.category) {
        case .succeeded:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.healthGreen)
                Text(total.category.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("очищено · \(ByteCountFormatter.string(fromByteCount: total.totalBytes, countStyle: .file))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.healthGreenText)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .background(Color(red: 0xF7 / 255, green: 0xFA / 255, blue: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        case .cleaning:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(total.category.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("· чистим").font(.system(size: 13)).foregroundStyle(Theme.accentGradientStart)
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .background(Theme.accentGradientStart.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        case .failed:
            statusRow(
                total: total,
                icon: "exclamationmark.circle.fill",
                color: .red,
                status: "ошибка"
            )
        case .cancelled:
            statusRow(
                total: total,
                icon: "stop.circle.fill",
                color: Theme.warningOrange,
                status: "остановлено"
            )
        case .pending:
            HStack(spacing: 12) {
                Circle().fill(Theme.trackBackground).frame(width: 16, height: 16)
                Text(total.category.displayName).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("в очереди").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .opacity(0.5)
        }
    }

    private func statusRow(
        total: CategoryTotal,
        icon: String,
        color: Color,
        status: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            Text(total.category.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(status).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    @ViewBuilder
    private var resultDetails: some View {
        if !viewModel.deletionFailures.isEmpty || !viewModel.unprocessedSmartCareItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !viewModel.deletionFailures.isEmpty {
                    Text("Ошибки удаления")
                        .font(.headline)
                    ForEach(viewModel.deletionFailures, id: \.item.id) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.item.path.path(percentEncoded: false))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(failure.item.path.path(percentEncoded: false))
                            Text(failure.reason)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                if !viewModel.unprocessedSmartCareItems.isEmpty {
                    Text("Не обработано объектов: \(viewModel.unprocessedSmartCareItems.count)")
                        .font(.callout)
                        .foregroundStyle(Theme.warningOrange)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        }
    }
}
