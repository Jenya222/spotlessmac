import SwiftUI

extension AppTab {
    var icon: String {
        switch self {
        case .care: return "house"
        case .cleaning: return "wand.and.stars"
        case .uninstall: return "trash"
        case .diskUsage: return "chart.pie"
        case .docker: return "shippingbox"
        case .settings: return "gearshape"
        }
    }
    var shortLabel: String {
        switch self {
        case .care: return "Уход"
        case .cleaning: return "Чистка"
        case .uninstall: return "Прогр."
        case .diskUsage: return "Диск"
        case .docker: return "Docker"
        case .settings: return "Настройки"
        }
    }
}

struct CareRailView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        VStack(spacing: 6) {
            logoTile
            ForEach(AppTab.mainTabs, id: \.self) { tab in
                railButton(for: tab)
            }
            Spacer()
            Button {
                selectedTab = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: Theme.moduleTileSize, height: Theme.moduleTileSize)
                    .foregroundStyle(selectedTab == .settings ? .white : Color(white: 0.55))
                    .background(selectedTab == .settings ? Color.white.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
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
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: Theme.logoTileSize, height: Theme.logoTileSize)
            .accessibilityLabel("Spotless Mac")
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
