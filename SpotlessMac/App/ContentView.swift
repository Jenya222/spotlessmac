import SwiftUI

enum AppTab: String, CaseIterable {
    case care = "Уход"
    case cleaning = "Чистка"
    case uninstall = "Программы"
    case diskUsage = "Диск"
    case memory = "Память"
    case docker = "Docker"
    case assistant = "Ассистент"
    case settings = "Настройки"

    static let mainTabs: [AppTab] = [.care, .cleaning, .uninstall, .diskUsage, .memory, .docker, .assistant]

    static func launchTab(from defaults: UserDefaults = .standard) -> AppTab {
        guard let value = defaults.string(forKey: "launchTab"),
              let tab = AppTab(rawValue: value), tab != .settings else { return .care }
        return tab
    }
}

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var dockerViewModel = DockerCleanupViewModel()
    @State private var memoryViewModel = MemoryViewModel()
    @State private var licenseManager = LicenseManager()
    @State private var uninstallViewModel = UninstallViewModel()
    @State private var assistantMemory = AssistantMemoryCache()
    @State private var assistant: AssistantViewModel?
    @Binding var selectedTab: AppTab
    @AppStorage("hasSeenFDAOnboarding") private var hasSeenFDAOnboarding = false
    @State private var showOnboarding = false
    @State private var showActivation = false

    var body: some View {
        HStack(spacing: 0) {
            CareRailView(selectedTab: $selectedTab)
            tabContent
        }
        .frame(minWidth: 920, minHeight: 604)
        .overlay(alignment: .topTrailing) {
            if selectedTab != .settings && selectedTab != .assistant {
                HStack(spacing: 10) {
                    licenseBadge
                    fdaBadge
                }
                .padding(10)
            }
        }
        .onAppear {
            if assistant == nil { assistant = makeAssistant() }
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
                onRecheck: { viewModel.checkFDA() }
            )
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .care:
            CareDashboardView(
                viewModel: viewModel, licenseManager: licenseManager,
                selectedTab: $selectedTab, showActivation: $showActivation, showOnboarding: $showOnboarding
            )
        case .cleaning:
            CleaningProgressView(viewModel: viewModel, selectedTab: $selectedTab)
        case .uninstall:
            UninstallerView(viewModel: uninstallViewModel, licenseManager: licenseManager)
        case .diskUsage:
            DiskOverviewView(viewModel: viewModel, licenseManager: licenseManager, onOpenDocker: { selectedTab = .docker })
        case .memory:
            MemoryView(viewModel: memoryViewModel)
        case .docker:
            DockerCleanupView(viewModel: dockerViewModel, licenseManager: licenseManager)
        case .assistant:
            if let assistant {
                AssistantView(
                    viewModel: assistant,
                    onOpenSettings: { selectedTab = .settings },
                    onScan: { Task { await viewModel.scan() } }
                )
            }
        case .settings:
            SpotlessMacSettingsView(
                viewModel: viewModel,
                licenseManager: licenseManager,
                assistant: assistant,
                showActivation: $showActivation,
                showOnboarding: $showOnboarding
            )
        }
    }

    private func makeAssistant() -> AssistantViewModel {
        let scan = viewModel
        let docker = dockerViewModel
        let uninstall = uninstallViewModel
        let memory = assistantMemory
        let tab = $selectedTab
        return AssistantViewModel(dependencies: .init(
            settingsStore: AssistantSettingsStore(),
            keyStore: KeychainAPIKeyStore(),
            makeClient: { settings, key in try LLMClientFactory.make(settings: settings, apiKey: key) },
            snapshot: {
                AssistantSnapshotBuilder.make(scan: scan, docker: docker, uninstall: uninstall, memory: memory.latest,
                                              volume: AssistantSnapshotBuilder.readVolume(), now: Date())
            },
            stagePlan: { plan in
                guard scan.stageSelection(Set(plan.itemIDs)) != nil else { return false }
                tab.wrappedValue = .diskUsage
                return true
            },
            conversationStore: ConversationStore(fileURL: ConversationStore.defaultFileURL()),
            homePath: NSHomeDirectory(),
            refreshContext: { await memory.refresh() }
        ))
    }

    @ViewBuilder
    private var licenseBadge: some View {
#if DEBUG
        Label("Активировано (DEBUG)", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.green)
#else
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
                    Label("Активировать", systemImage: "lock").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            } else {
                Label("Пробный", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
#endif
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
                Label("FDA", systemImage: "exclamationmark.shield").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }
}

// Kept internal (not private) so SmartCareConfirmSheet can reuse it.
struct ScanItemRow: View {
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
                Text(item.path.lastPathComponent).lineLimit(1)
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
