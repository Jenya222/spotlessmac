import SwiftUI

struct CareDashboardView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager
    @Binding var selectedTab: AppTab
    @Binding var showActivation: Bool
    @Binding var showOnboarding: Bool

    @AppStorage("lastSmartCareTimestamp") private var lastSmartCareTimestamp: Double = 0
    @State private var memorySample: MemorySample?
    @State private var diskOverview: DiskSpaceOverview?
    @State private var showConfirmSheet = false

    private var cleanableBytes: Int64 {
        viewModel.cleanableItems.reduce(0) { $0 + $1.size }
    }
    private var healthScore: Int {
        HealthScoreCalculator.compute(
            cleanableBytes: cleanableBytes,
            freeDiskFraction: diskOverview?.availableFraction ?? 1,
            fdaStatus: viewModel.fdaStatus
        )
    }
    private var band: HealthBand { HealthScoreCalculator.band(for: healthScore) }

    private var memorySubtitle: String {
        guard let sample = memorySample else { return "…" }
        let pressure = MemoryView.label(for: sample.system.pressure).lowercased()
        let header = "Давление: \(pressure) · своп \(MemoryVerdict.format(sample.system.swapUsed))"
        let top = sample.groups.filter { $0.kind == .userApp }.prefix(3)
            .map { "\($0.displayName) — \(MemoryVerdict.format($0.footprint))" }
        return ([header] + top).joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 0) {
            centerColumn
            statusColumn
        }
        .task {
            // Own task so the memory card fills as soon as its sample is ready,
            // instead of waiting for the (much longer) scan below.
            memorySample = await MemoryMonitor().sample()
        }
        .task {
            if viewModel.items.isEmpty { await viewModel.scan() }
            diskOverview = await DiskSpaceService.overview()
        }
        .sheet(isPresented: $showConfirmSheet) {
            SmartCareConfirmSheet(
                viewModel: viewModel,
                onConfirm: {
                    showConfirmSheet = false
                    selectedTab = .cleaning
                    viewModel.startSmartCare(licenseManager: licenseManager)
                },
                onCancel: { showConfirmSheet = false }
            )
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(band == .attention ? "Вашему Mac нужна забота" : "Ваш Mac в отличной форме")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(lastCareSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            healthRing

            Button {
                if licenseManager.canClean {
                    Task {
                        await viewModel.prepareSmartCare()
                        showConfirmSheet = true
                    }
                } else {
                    showActivation = true
                }
            } label: {
                Text("Запустить умный уход")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 42)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(viewModel.isScanning || viewModel.isPreparingSmartCare)

            Text("Проверит безопасные кеши и логи — \(ByteCountFormatter.string(fromByteCount: cleanableBytes, countStyle: .file)) можно освободить")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.dashboardBackground)
    }

    @ViewBuilder
    private var healthRing: some View {
        if viewModel.isScanning && viewModel.items.isEmpty {
            ProgressView().frame(width: Theme.dashboardRingSize, height: Theme.dashboardRingSize)
        } else {
            ZStack {
                Circle().stroke(Theme.trackBackground, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(healthScore) / 100)
                    .stroke(band.color, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text("\(healthScore)")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 5) {
                        Circle().fill(band.color).frame(width: 7, height: 7)
                        Text(band.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(band.color)
                    }
                }
            }
            .padding(12)
            .frame(width: Theme.dashboardRingSize, height: Theme.dashboardRingSize)
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("СОСТОЯНИЕ СИСТЕМ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 20)

            statCard(iconBackground: Theme.healthGreen.opacity(0.15), icon: "checkmark.circle.fill",
                     iconColor: Theme.healthGreenText, title: "Чистота",
                     subtitle: "\(ByteCountFormatter.string(fromByteCount: cleanableBytes, countStyle: .file)) мусора найдено")

            Button { selectedTab = .memory } label: {
                statCard(iconBackground: Theme.accentGradientStart.opacity(0.12), icon: "memorychip",
                         iconColor: Theme.accentGradientStart, title: "Память",
                         subtitle: memorySubtitle)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Открыть раздел «Память»")

            statCard(iconBackground: Theme.warningOrange.opacity(0.15), icon: "chart.pie.fill",
                     iconColor: Theme.warningOrange, title: "Диск",
                     subtitle: diskOverview.map { "\($0.formattedAvailable) из \($0.formattedTotal) свободно" } ?? "…")

            Spacer()
            protectionCard
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: Theme.statusColumnWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    private func statCard(iconBackground: Color, icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    // Repurposes the mockup's "Защита в реальном времени" card to show a
    // real status this app actually has (Full Disk Access) instead of a
    // fabricated protection feature that doesn't exist.
    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Полный доступ к диску").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Group {
                switch viewModel.fdaStatus {
                case .granted:
                    statusDot(color: Theme.healthGreen, text: "включён")
                case .denied:
                    Button { showOnboarding = true } label: {
                        statusDot(color: Theme.warningOrange, text: "не предоставлен")
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                case .unknown:
                    statusDot(color: Theme.textTertiary, text: "проверяется…")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.railGraphite)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private func statusDot(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(Color(white: 0.8))
        }
    }

    private var lastCareSubtitle: String {
        guard lastSmartCareTimestamp > 0 else { return "Ещё не выполнялась" }
        let date = Date(timeIntervalSince1970: lastSmartCareTimestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        let prefix = Calendar.current.isDateInToday(date) ? "сегодня в " : ""
        return "Последний уход — \(prefix)\(formatter.string(from: date))"
    }
}
