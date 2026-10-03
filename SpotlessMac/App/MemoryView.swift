import AppKit
import Charts
import SwiftUI

struct MemoryView: View {
    var viewModel: MemoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let sample = viewModel.latest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(sample.system)
                        historyChart
                        Text(MemoryVerdict.text(system: sample.system, groups: sample.groups))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        sources(total: sample.system.physical)
                    }
                    .padding(24)
                }
            } else {
                ProgressView("Собираем данные о памяти…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.dashboardBackground.opacity(0.38))
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: Binding(
            get: { viewModel.quitState != .idle },
            set: { if !$0 { viewModel.dismissQuit() } }
        )) {
            MemoryQuitSheet(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.accentGradient)
                Image(systemName: "memorychip")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Память").font(.title2.bold())
                Text("Что держит оперативную память и своп")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.resortNow()
            } label: {
                Label("Пересортировать", systemImage: "arrow.up.arrow.down")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Summary

    private func summary(_ system: SystemMemorySnapshot) -> some View {
        HStack(spacing: 10) {
            pressureTile(system.pressure)
            tile("Используется", MemoryVerdict.format(system.used),
                 detail: "из \(MemoryVerdict.format(system.physical))")
            tile("Сжато", MemoryVerdict.format(system.compressed), detail: nil)
            tile("Своп", MemoryVerdict.format(system.swapUsed),
                 detail: system.swapTotal > 0 ? "из \(MemoryVerdict.format(system.swapTotal))" : nil)
            tile("Кэш файлов", MemoryVerdict.format(system.cachedFiles), detail: "освобождается сам")
        }
    }

    private func pressureTile(_ pressure: MemoryPressure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Давление").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Circle().fill(Self.color(for: pressure)).frame(width: 10, height: 10)
                Text(Self.label(for: pressure)).font(.system(size: 17, weight: .bold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private func tile(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    static func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return Theme.healthGreen
        case .warning: return Theme.warningOrange
        case .critical: return Theme.destructiveEnd
        case .unknown: return Theme.textTertiary
        }
    }

    static func label(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: return "Норма"
        case .warning: return "Высокое"
        case .critical: return "Критическое"
        case .unknown: return "—"
        }
    }

    // MARK: History

    private var historyChart: some View {
        let bands = Self.pressureBands(viewModel.history)
        return Chart {
            // Pressure tint first so the lines are drawn on top of it.
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Начало", band.start), xEnd: .value("Конец", band.end))
                    .foregroundStyle(Self.color(for: band.pressure).opacity(0.12))
            }
            ForEach(viewModel.history) { point in
                LineMark(x: .value("Время", point.date), y: .value("ГБ", Self.gigabytes(point.swapUsed)),
                         series: .value("Метрика", "Своп"))
                    .foregroundStyle(by: .value("Метрика", "Своп"))
                LineMark(x: .value("Время", point.date), y: .value("ГБ", Self.gigabytes(point.compressed)),
                         series: .value("Метрика", "Сжато"))
                    .foregroundStyle(by: .value("Метрика", "Сжато"))
            }
        }
        .chartForegroundStyleScale(["Своп": Theme.accentGradientStart, "Сжато": Theme.warningOrange])
        .chartYAxisLabel("ГБ")
        .frame(height: 120)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    /// One contiguous background band per run of equal pressure. A sample's pressure
    /// holds until the next sample, so a run ends where the next run begins and the
    /// bands tile the plot without gaps. Fewer than two points yield no bands.
    private struct PressureBand: Identifiable {
        let start: Date
        let end: Date
        let pressure: MemoryPressure
        var id: Date { start }
    }

    private static func pressureBands(_ history: [MemoryHistoryPoint]) -> [PressureBand] {
        var bands: [PressureBand] = []
        for (point, next) in zip(history, history.dropFirst()) {
            if let last = bands.last, last.pressure == point.pressure {
                bands[bands.count - 1] = PressureBand(start: last.start, end: next.date, pressure: last.pressure)
            } else {
                bands.append(PressureBand(start: point.date, end: next.date, pressure: point.pressure))
            }
        }
        return bands
    }

    private static func gigabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    // MARK: Sources

    private func sources(total: UInt64) -> some View {
        let apps = viewModel.displayedGroups.filter { $0.kind == .userApp }
        let rest = viewModel.displayedGroups.filter { $0.kind != .userApp }
        return VStack(alignment: .leading, spacing: 6) {
            Text("ИСТОЧНИКИ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            ForEach(apps) { group in row(group, total: total) }
            if !rest.isEmpty {
                Text("КОМАНДНАЯ СТРОКА И СИСТЕМА")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 10)
                ForEach(rest) { group in row(group, total: total) }
            }
        }
    }

    private func row(_ group: AppMemoryGroup, total: UInt64) -> some View {
        let expanded = viewModel.expandedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if expanded { viewModel.expandedGroupIDs.remove(group.id) } else { viewModel.expandedGroupIDs.insert(group.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                icon(for: group).frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.displayName).font(.system(size: 13, weight: .semibold))
                        Text("\(group.processes.count) проц.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        if group.hasPartialData {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .help("Нужны права администратора для точных данных")
                        }
                    }
                    ProgressView(value: total > 0 ? min(1, Double(group.footprint) / Double(total)) : 0)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(MemoryVerdict.format(group.footprint)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    Text("вытеснено ≈ \(MemoryVerdict.format(group.pushedOut))")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .frame(width: 150, alignment: .trailing)

                if viewModel.hasRunningApplication(in: group) {
                    Button("Завершить") { viewModel.requestQuit(group) }
                        .controlSize(.small)
                } else {
                    Color.clear.frame(width: 72, height: 1)
                }
            }
            if expanded {
                helperSummary(group)
                ForEach(group.processes.prefix(40), id: \.pid) { process in
                    HStack {
                        Text(process.role?.label ?? process.name).font(.system(size: 11.5)).lineLimit(1)
                            .help(process.name)
                        Text("PID \(process.pid)").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(process.isPartial ? "нет доступа" : MemoryVerdict.format(process.footprint))
                            .font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(process.isPartial ? Theme.textTertiary : Theme.textPrimary)
                    }
                    .padding(.leading, 56)
                }
                if group.processes.count > 40 {
                    Text("и ещё \(group.processes.count - 40)…")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.leading, 56)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
    }

    /// "Вкладки 12 · 6,9 GB · Расширения 4 · 410 MB · …" plus, for browsers,
    /// where to find the per-tab breakdown that only the browser itself knows.
    @ViewBuilder
    private func helperSummary(_ group: AppMemoryGroup) -> some View {
        let totals = group.roleTotals
        if !totals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(totals.map { "\($0.role.summaryLabel) \($0.count) · \(MemoryVerdict.format($0.bytes))" }
                    .joined(separator: "   "))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if group.looksLikeBrowser {
                    Label("Какая именно вкладка или расширение занимает память, показывает диспетчер задач браузера: в Chrome — Shift+Esc или «Окно → Диспетчер задач».",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 56)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func icon(for group: AppMemoryGroup) -> some View {
        if let path = group.bundlePath {
            Image(nsImage: AppIconCache.icon(forFile: path)).resizable()
        } else {
            Image(systemName: group.kind == .system ? "gearshape.2" : "terminal")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// `NSWorkspace.icon(forFile:)` hits the disk and returns a new image on every call;
/// rows re-render on each 2 s sample, so icons are cached per bundle path. Kept out of
/// the view model so filling it never triggers Observation updates.
@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}
