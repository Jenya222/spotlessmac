import SwiftUI
import AppKit

struct UninstallerView: View {
    var licenseManager: LicenseManager

    @State private var viewModel = UninstallViewModel()
    @State private var showConfirmation = false
    @State private var showActivation = false

    var body: some View {
        NavigationSplitView {
            appList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detailPane
        }
        .task {
            if viewModel.apps.isEmpty { await viewModel.loadApps() }
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
                List(viewModel.apps, selection: Binding(
                    get: { viewModel.selectedApp?.id },
                    set: { id in
                        if let app = viewModel.apps.first(where: { $0.id == id }) {
                            Task { await viewModel.select(app) }
                        }
                    }
                )) { app in
                    AppRow(app: app).tag(app.id)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Обновить") { Task { await viewModel.loadApps() } }
                    .disabled(viewModel.isLoadingApps)
            }
        }
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
            if let warning = viewModel.largeLeftoverWarning {
                warningBanner(for: warning)
            }
            List {
                ForEach(viewModel.leftoversByLocation, id: \.location) { group in
                    Section(group.location) {
                        ForEach(group.items) { item in
                            LeftoverRow(item: item, isFlagged: item.size >= UninstallViewModel.largeLeftoverThreshold) {
                                viewModel.toggleSelection(item)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .confirmationDialog(
            "Переместить выбранное в Корзину?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Переместить в Корзину", role: .destructive) {
                Task {
                    await viewModel.uninstall()
                    if viewModel.failures.isEmpty && !licenseManager.isActivated {
                        licenseManager.recordClean()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(viewModel.selectedLeftovers
                .map { $0.path.path(percentEncoded: false) }
                .joined(separator: "\n"))
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
                    Text("Удалить \(app.name)").font(.system(size: 22, weight: .heavy))
                    Text("\(viewModel.totalLeftoverCount) объектов · будет освобождено \(viewModel.formattedTotalLeftoverSize)")
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
            Button("Снять выделение") { viewModel.selectNone() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!viewModel.hasSelection)
            Button {
                if licenseManager.canClean {
                    showConfirmation = true
                } else {
                    showActivation = true
                }
            } label: {
                Text("Удалить полностью")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 24)
                    .background(Theme.destructiveGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasSelection || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Rows

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path(percentEncoded: false)))
                .resizable()
                .frame(width: 24, height: 24)
            Text(app.name)
                .lineLimit(1)
        }
    }
}

private struct LeftoverRow: View {
    let item: LeftoverItem
    let isFlagged: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Text(item.path.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(item.formattedSize)
                .monospacedDigit()
                .foregroundStyle(isFlagged ? Theme.warningOrange : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
