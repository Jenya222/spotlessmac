import SwiftUI
import AppKit

struct DiskOverviewView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager
    var onOpenDocker: () -> Void = {}
    @State private var analysis = StorageAnalysisViewModel()

    @State private var overview: DiskSpaceOverview?
    @State private var largestFolders: [FolderEntry] = []
    @State private var showDrillDown = false
    @State private var drillDownURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var showLargeFiles = false
    @State private var showStorageRecovery = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let overview, overview.capacityKnown {
                    segmentedBar(overview)
                    legend(overview)
                    if !overview.isComplete { Text("Измерение неполное: часть папок недоступна. В сегментах показан измеренный объём.").font(.caption).foregroundStyle(.orange) }
                }
                storageRecoveryCard
                sourcesSection
            }
            .padding(24)
        }
        .task {
            overview = await DiskSpaceService.overview(sourceResults: [])
            await analysis.scanSources()
            overview = await DiskSpaceService.overview(sourceResults: analysis.sourceResults)
        }
        .onDisappear { analysis.cancel() }
        .onChange(of: viewModel.recoveryPreviewRequested, initial: true) { _, requested in
            guard requested else { return }
            viewModel.recoveryPreviewRequested = false
            showStorageRecovery = true
        }
        .sheet(isPresented: $showDrillDown) {
            NavigationStack {
                DiskUsageView(startingURL: drillDownURL)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showDrillDown = false } } }
            }
            .frame(width: 640, height: 480)
        }
        .sheet(isPresented: $showLargeFiles) {
            NavigationStack {
                LargeFilesView(viewModel: viewModel, licenseManager: licenseManager)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showLargeFiles = false } } }
            }
            .frame(width: 640, height: 480)
        }
        .sheet(isPresented: $showStorageRecovery, onDismiss: {
            viewModel.clearAssistantStaging()
            refreshDiskOverview()
        }) {
            StorageRecoveryView(viewModel: viewModel, licenseManager: licenseManager)
        }
    }

    private var storageRecoveryCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.warningOrange)
                .frame(width: 48, height: 48)
                .background(Theme.warningBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Освободить место")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if viewModel.items.isEmpty {
                    Text("Найдём кеши, старые установщики и крупные файлы в безопасных папках.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(recoverySummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            Button {
                Task {
                    if viewModel.items.isEmpty { await viewModel.scan() }
                    showStorageRecovery = true
                }
            } label: {
                if viewModel.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        viewModel.items.isEmpty ? "Найти файлы" : "Посмотреть результаты",
                        systemImage: "magnifyingglass"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanning || viewModel.isCleaning)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.warningBorder))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private var recoverySummary: String {
        let safeBytes = viewModel.cleanableItems.reduce(Int64(0)) { $0 + $1.size }
        let reviewCount = viewModel.items.filter { !$0.category.isBatchCleanable }.count
        let safe = ByteCountFormatter.string(fromByteCount: safeBytes, countStyle: .file)
        return "Безопасно очистить: \(safe) · проверить файлов: \(reviewCount)"
    }

    private func refreshDiskOverview() {
        Task {
            overview = await DiskSpaceService.overview(sourceResults: [])
            await analysis.scanSources()
            overview = await DiskSpaceService.overview(sourceResults: analysis.sourceResults)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(DiskSpaceService.volumeDisplayName)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let overview {
                Text("\(overview.formattedUsed) занято · \(overview.formattedAvailable) свободно")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Показать крупные файлы") {
                Task {
                    if viewModel.items.isEmpty { await viewModel.scan() }
                    showLargeFiles = true
                }
            }
                .buttonStyle(.bordered)
        }
    }

    private func segmentedBar(_ overview: DiskSpaceOverview) -> some View {
        GeometryReader { geo in
            let total = max(1, overview.usedBytes)
            HStack(spacing: 0) {
                segment(width: geo.size.width * CGFloat(overview.unclassifiedBytes) / CGFloat(total), color: Theme.accentGradientEnd)
                segment(width: geo.size.width * CGFloat(overview.applicationsBytes) / CGFloat(total), color: Theme.accentGradientStart)
                segment(width: geo.size.width * CGFloat(overview.documentsBytes) / CGFloat(total), color: Theme.healthGreen)
            }
        }
        .frame(height: 16)
        .background(Theme.trackBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }

    private func legend(_ overview: DiskSpaceOverview) -> some View {
        HStack(spacing: 18) {
            legendDot(color: Theme.accentGradientEnd, label: "Прочее и неразобранное", bytes: overview.unclassifiedBytes)
            legendDot(color: Theme.accentGradientStart, label: "Программы", bytes: overview.applicationsBytes)
            legendDot(color: Theme.healthGreen, label: "Документы", bytes: overview.documentsBytes)
        }
    }

    private func legendDot(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text("\(label) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.35))
        }
    }

    private func chooseRoot(kind: StorageRootKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = kind == .projects ? "Выберите папку проектов. Исходники не предлагаются к удалению." : "Выберите папку hub с репозиториями Hugging Face."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try StorageRootRegistry.register(url, kind: kind); refreshDiskOverview() }
        catch { analysis.errorMessage = "Выберите конкретную папку, а не весь диск или домашний каталог." }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ИСТОЧНИКИ ЗАНЯТОГО МЕСТА").font(.caption.bold())
                Spacer()
                if analysis.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Остановить") { analysis.cancel() }
                } else { Button("Обновить") { refreshDiskOverview() } }
            }
            HStack {
                Button("Добавить папку проектов") { chooseRoot(kind: .projects) }
                Button("Добавить кэш Hugging Face") { chooseRoot(kind: .huggingFace) }
            }
            if let error = analysis.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Размер на диске. Измеренные источники не повторяют категории macOS; общие APFS-данные могут влиять на итог.")
                .font(.caption).foregroundStyle(.secondary)
            if analysis.isStale { Text("Не обновлено — показан предыдущий снимок").font(.caption).foregroundStyle(.orange) }
            ForEach(analysis.sourceResults) { result in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Button(result.source.title) {
                            drillDownURL = result.source.url; showDrillDown = true
                        }.disabled(result.measurement == nil)
                        Spacer()
                        if let size = result.measurement {
                            Text((size.isComplete ? "" : "Не менее ") + ByteCountFormatter.string(fromByteCount: size.allocatedBytes, countStyle: .file)).monospacedDigit()
                        } else { Text("Недоступно").foregroundStyle(.secondary) }
                        if result.source.url.lastPathComponent == "Containers" { Button("Docker", action: onOpenDocker) }
                    }
                    Text(result.errorMessage ?? result.source.explanation).font(.caption).foregroundStyle(.secondary)
                    Text(result.source.url.path(percentEncoded: false)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(12).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let date = analysis.sampledAt { Text("Измерено: \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var largestFoldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("КРУПНЕЙШИЕ ПАПКИ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            let maxSize = largestFolders.first?.size ?? 1
            ForEach(largestFolders) { entry in
                Button {
                    drillDownURL = entry.url
                    showDrillDown = true
                } label: {
                    folderRow(entry, maxSize: maxSize)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func folderRow(_ entry: FolderEntry, maxSize: Int64) -> some View {
        let isFlagged = entry.name == "Downloads"
        return HStack(spacing: 13) {
            Image(systemName: folderIcon(for: entry.name))
                .foregroundStyle(isFlagged ? Theme.warningOrange : Theme.accentGradientStart)
                .frame(width: 34, height: 34)
                .background(isFlagged ? Theme.warningBackground : Theme.accentGradientStart.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(entry.formattedSize).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
                GeometryReader { geo in
                    let proportion = maxSize > 0 ? CGFloat(entry.size) / CGFloat(maxSize) : 0
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isFlagged ? Theme.warningOrange : Theme.accentGradientStart)
                        .frame(width: max(2, geo.size.width * proportion))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 7)
                .background(Theme.trackBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func folderIcon(for name: String) -> String {
        switch name {
        case "Documents": return "doc.fill"
        case "Applications": return "square.grid.2x2"
        case "Downloads": return "arrow.down.circle"
        default: return "folder.fill"
        }
    }
}
