import SwiftUI

enum AppTab: String, CaseIterable {
    case care = "Уход"
    case cleaning = "Чистка"
    case uninstall = "Программы"
    case diskUsage = "Диск"
}

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var licenseManager = LicenseManager()
    @State private var selectedTab: AppTab = .care
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
            HStack(spacing: 10) {
                licenseBadge
                fdaBadge
            }
            .padding(10)
        }
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
            Text("TODO: CareDashboardView (Task 10)").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cleaning:
            Text("TODO: CleaningProgressView (Task 11)").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .uninstall:
            UninstallerView(licenseManager: licenseManager)
        case .diskUsage:
            Text("TODO: DiskOverviewView (Task 12)").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
