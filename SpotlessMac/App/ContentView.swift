import SwiftUI

private enum AppTab: String, CaseIterable {
    case clean = "Очистка"
    case uninstall = "Деинсталлятор"
    case largeFiles = "Крупные файлы"
    case diskUsage = "Диск"
}

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var licenseManager = LicenseManager()
    @State private var selectedTab: AppTab = .clean
    @AppStorage("hasSeenFDAOnboarding") private var hasSeenFDAOnboarding = false
    @State private var showOnboarding = false
    @State private var showActivation = false

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            tabContent
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            viewModel.checkFDA()
            if !hasSeenFDAOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            FDAOnboardingView(
                onDismiss: {
                    hasSeenFDAOnboarding = true
                    showOnboarding = false
                    viewModel.checkFDA()
                },
                onRecheck: {
                    viewModel.checkFDA()
                }
            )
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
            }
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 12) {
            Text("SpotlessMac")
                .font(.title2.bold())

            Spacer()

            Picker("Раздел", selection: $selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 460)

            licenseBadge
            fdaBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var licenseBadge: some View {
        switch licenseManager.state {
        case .activated:
            Label("Активировано", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .trial(let used, let allowed):
            if used >= allowed {
                Button {
                    showActivation = true
                } label: {
                    Label("Активировать", systemImage: "lock")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            } else {
                Label("Пробный", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fdaBadge: some View {
        switch viewModel.fdaStatus {
        case .granted:
            Label("FDA", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied:
            Button {
                showOnboarding = true
            } label: {
                Label("FDA", systemImage: "exclamationmark.shield")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .clean:
            cleanTab
        case .uninstall:
            UninstallerView(licenseManager: licenseManager)
        case .largeFiles:
            LargeFilesView(viewModel: viewModel, licenseManager: licenseManager)
        case .diskUsage:
            DiskUsageView()
        }
    }

    // MARK: - Clean tab (existing scan/delete flow)

    private var cleanTab: some View {
        VStack(spacing: 0) {
            cleanToolbar
            Divider()
            if !viewModel.deletionFailures.isEmpty {
                failureBanner
                Divider()
            }
            if let error = viewModel.scanError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.red.opacity(0.1))
                .foregroundStyle(.red)
                Divider()
            }
            resultsList
            Divider()
            statusBar
        }
    }

    private var cleanToolbar: some View {
        HStack(spacing: 12) {
            if viewModel.hasSelection {
                Text(viewModel.formattedTotalSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.opacity)
            }

            Button("Очистить выбранное") {
                if licenseManager.canClean {
                    Task {
                        await viewModel.delete()
                        if !licenseManager.isActivated {
                            licenseManager.recordClean()
                        }
                    }
                } else {
                    showActivation = true
                }
            }
            .disabled(!viewModel.hasSelection || viewModel.isDeleting || viewModel.isScanning)

            if viewModel.isScanning || viewModel.isDeleting {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Button("Сканировать") {
                Task { await viewModel.scan() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanning || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.default, value: viewModel.hasSelection)
    }

    private var resultsList: some View {
        List(viewModel.cleanableItems) { item in
            ScanItemRow(item: item) {
                viewModel.toggleSelection(item)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.cleanableItems.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "Нажмите «Сканировать»",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Будут найдены кеши и другие ненужные файлы")
                )
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.cleanableItems.count) элементов")
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.hasSelection {
                Button("Снять выделение") { viewModel.selectNone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            } else if !viewModel.cleanableItems.isEmpty {
                Button("Выбрать все") { viewModel.selectAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(viewModel.deletionFailures.count) файлов не удалось переместить в Корзину",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.bold())
            ForEach(viewModel.deletionFailures, id: \.item.id) { failure in
                HStack(alignment: .top, spacing: 4) {
                    Text("·")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.path.lastPathComponent).bold()
                        Text(failure.reason).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .foregroundStyle(.orange)
    }
}

// MARK: - Row

private struct ScanItemRow: View {
    let item: ScanItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .imageScale(.large)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)

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
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
