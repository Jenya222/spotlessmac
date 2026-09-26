import SwiftUI

extension AppTab {
    var icon: String {
        switch self {
        case .care: return "house"
        case .cleaning: return "wand.and.stars"
        case .uninstall: return "trash"
        case .diskUsage: return "chart.pie"
        case .docker: return "shippingbox"
        }
    }
    var shortLabel: String {
        switch self {
        case .care: return "Уход"
        case .cleaning: return "Чистка"
        case .uninstall: return "Прогр."
        case .diskUsage: return "Диск"
        case .docker: return "Docker"
        }
    }
}

struct CareRailView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        VStack(spacing: 6) {
            logoTile
            ForEach(AppTab.allCases, id: \.self) { tab in
                railButton(for: tab)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: Theme.moduleTileSize, height: Theme.moduleTileSize)
                    .foregroundStyle(Color(white: 0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
            .help("Настройки")
        }
        .padding(.vertical, 14)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.railGraphite)
    }

    private var logoTile: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Theme.logoTileSize, height: Theme.logoTileSize)
            .background(Theme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 8)
    }

    private func railButton(for tab: AppTab) -> some View {
        let selected = tab == selectedTab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon).font(.system(size: 16))
                Text(tab.shortLabel).font(.system(size: 8, weight: .semibold))
            }
            .frame(width: Theme.moduleTileSize, height: Theme.moduleTileSize)
            .foregroundStyle(selected ? .white : Color(white: 0.58))
            .background(selected ? Color.white.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }
}
