import SwiftUI
import AppKit

struct UninstallerView: View {
    @Bindable var viewModel: UninstallViewModel
    var licenseManager: LicenseManager

    @Environment(\.askAssistant) private var askAssistant
    @State private var showConfirmation = false
    @State private var showActivation = false
    @State private var pendingItems: [LeftoverItem] = []
    @State private var pendingCache: [ScanItem] = []
    @State private var cacheFailure: String?

    var body: some View {
        // Plain split instead of NavigationSplitView: its toolbar items were drawn
        // into the window title bar and overlapped the rail and content.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebarHeader
                Divider()
                appList
            }
            .frame(width: 260)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if viewModel.apps.isEmpty { await viewModel.loadApps() }
        }
        .sheet(isPresented: Binding(get: { !pendingCache.isEmpty }, set: { if !$0 { pendingCache = [] } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Переместить кэш в Корзину?").font(.title2.bold())
                Text("Закройте приложение. Программа и личные данные сохраняются.").foregroundStyle(.secondary)
                List(pendingCache) { item in
                    VStack(alignment: .leading) {
                        Text(item.path.path(percentEncoded: false)).textSelection(.enabled)
                        Text(item.formattedSize).font(.caption)
                    }
                }
                HStack {
                    Button("Отмена") { pendingCache = [] }
                    Spacer()
                    Button("Переместить в Корзину", role: .destructive) {
                        let snapshot = pendingCache; pendingCache = []
                        Task {
                            guard licenseManager.canClean else { showActivation = true; return }
                            let failures = await viewModel.cleanCache(snapshot)
                            cacheFailure = failures.first?.reason
                            if failures.count < snapshot.count && !licenseManager.isActivated { licenseManager.recordClean() }
                        }
                    }
                }
            }.padding(20).frame(width: 650, height: 450)
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
            }
        }
        .alert(
            "Не удалось удалить часть файлов",
            isPresented: Binding(
                get: { !viewModel.failures.isEmpty },
                set: { if !$0 { viewModel.failures = [] } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.failures = [] }
        } message: {
            Text(viewModel.failures.map { "\($0.item.path.lastPathComponent): \($0.reason)" }
                .joined(separator: "\n"))
        }
    }

    // MARK: - Sidebar

    private var appList: some View {
        Group {
            if viewModel.isLoadingApps {
                ProgressView("Поиск приложений…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.sortedApps, selection: Binding(
                    get: { viewModel.selectedApp?.id },
                    set: { id in
                        if let app = viewModel.apps.first(where: { $0.id == id }) {
                            Task { await viewModel.select(app) }
                        }
                    }
                )) { app in
                    AppRow(app: app, summary: viewModel.storageSummaries[app.id]).tag(app.id)
                }
                .listStyle(.sidebar)
                .disabled(viewModel.isDeleting)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Toggle("По размеру", isOn: $viewModel.sortBySize)
                .toggleStyle(.checkbox)
                .pointingHandCursor()
            Spacer()
            Button("Обновить", systemImage: "arrow.clockwise") { Task { await viewModel.loadApps() } }
                .buttonStyle(.borderedHand)
                .controlSize(.small)
                .disabled(viewModel.isLoadingApps || viewModel.isDeleting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if viewModel.selectedApp == nil {
            ContentUnavailableView(
                "Выберите приложение",
                systemImage: "trash.square",
                description: Text("Слева выберите приложение, чтобы найти его файлы")
            )
        } else if viewModel.isScanningLeftovers {
            ProgressView("Поиск связанных файлов…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            leftoversView
        }
    }

    private var leftoversView: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            if let app = viewModel.selectedApp, let summary = viewModel.storageSummaries[app.id] {
                Text("Программа: \(ByteCountFormatter.string(fromByteCount: summary.bundleBytes, countStyle: .file)) · Кэш: \(ByteCountFormatter.string(fromByteCount: summary.cacheBytes, countStyle: .file)) · Данные: \(ByteCountFormatter.string(fromByteCount: summary.dataBytes, countStyle: .file))")
                    .font(.caption).padding(.horizontal, 16)
                if !summary.isComplete { Text("Некоторые данные недоступны; показан измеренный объём.").font(.caption).foregroundStyle(.orange).padding(.horizontal, 16) }
            }
            if let cacheFailure { Text(cacheFailure).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
            if let warning = viewModel.largeLeftoverWarning {
                warningBanner(for: warning)
            }
            List {
                ForEach(viewModel.leftoversByLocation, id: \.location) { group in
                    Section(group.location) {
                        ForEach(group.items) { item in
                            LeftoverRow(
                                item: item,
                                isFlagged: item.size >= UninstallViewModel.largeLeftoverThreshold,
                                onToggle: { viewModel.toggleSelection(item) },
                                onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in
                                    { action(AssistantSnapshotBuilder.focus(for: item, appName: viewModel.selectedApp?.name)) }
                                }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .sheet(isPresented: $showConfirmation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Переместить выбранное в Корзину?").font(.title2.bold())
                Text("Программа, кэш и личные данные показаны отдельно. Корзина продолжает занимать место.").font(.callout).foregroundStyle(.secondary)
                List(pendingItems) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.path.path(percentEncoded: false)).textSelection(.enabled)
                        Text(item.formattedSize + " · " + item.dispositionLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Отмена") { showConfirmation = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Переместить в Корзину", role: .destructive) {
                        let snapshot = pendingItems; showConfirmation = false
                        Task {
                            guard licenseManager.canClean else { showActivation = true; return }
                            await viewModel.uninstall(items: snapshot)
                            if viewModel.failures.count < snapshot.count && !licenseManager.isActivated { licenseManager.recordClean() }
                        }
                    }.disabled(pendingItems.isEmpty || viewModel.isDeleting)
                }
            }.padding(20).frame(minWidth: 650, minHeight: 450)
        }
    }

    private var appHeader: some View {
        HStack(spacing: 14) {
            if let app = viewModel.selectedApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 22, weight: .heavy))
                    Text("\(viewModel.totalLeftoverCount) объектов · найдено \(viewModel.formattedTotalLeftoverSize)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(viewModel.formattedTotalLeftoverSize).font(.system(size: 22, weight: .heavy))
                    Text("всего").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func warningBanner(for item: LeftoverItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warningOrange)
            Text("Каталог «\(item.location)» очень большой — проверьте, нет ли в нём нужных данных, прежде чем удалять.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0x8A / 255, green: 0x6A / 255, blue: 0x2E / 255))
        }
        .padding(11)
        .background(Theme.warningBackground)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.warningBorder))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Text("Выбрано \(viewModel.formattedTotalSize) из \(viewModel.totalLeftoverCount) объектов")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Очистить поддерживаемый кэш") {
                guard licenseManager.canClean else { showActivation = true; return }
                pendingCache = viewModel.supportedCacheItems
            }.disabled(viewModel.supportedCacheItems.isEmpty || viewModel.isDeleting)
            Button("Снять выделение") { viewModel.selectNone() }
                .buttonStyle(.plainHand)
                .foregroundStyle(Color.accentColor)
                .disabled(!viewModel.hasSelection)
            Button {
                if licenseManager.canClean {
                    pendingItems = viewModel.selectedLeftovers
                    showConfirmation = true
                } else {
                    showActivation = true
                }
            } label: {
                Text("Переместить выбранное в Корзину")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 24)
                    .background(Theme.destructiveGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plainHand)
            .disabled(!viewModel.hasSelection || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Rows

private struct AppRow: View {
    let app: InstalledApp
    var summary: AppStorageSummary?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path(percentEncoded: false)))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text(app.name).lineLimit(1)
                if let summary {
                    Text((summary.isComplete ? "" : "Не менее ") + ByteCountFormatter.string(fromByteCount: summary.confirmedTotalBytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                } else { Text("Размер не измерен").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .pointingHandCursor()
    }
}

private struct LeftoverRow: View {
    let item: LeftoverItem
    let isFlagged: Bool
    let onToggle: () -> Void
    var onAsk: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plainHand)

            Text(item.dispositionLabel + " · " + item.path.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let onAsk { AskAssistantButton(action: onAsk) }

            Text(item.formattedSize)
                .monospacedDigit()
                .foregroundStyle(isFlagged ? Theme.warningOrange : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .pointingHandCursor()
        .askAssistantMenu(onAsk)
    }
}
