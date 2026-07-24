import SwiftUI

enum Theme {
    // MARK: Colors (from the "Центр ухода" mockup spec)
    static let railGraphite = Color(red: 0x1C / 255, green: 0x21 / 255, blue: 0x30 / 255)
    static let accentGradientStart = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xFF / 255)
    static let accentGradientEnd = Color(red: 0x3D / 255, green: 0x8B / 255, blue: 0xFF / 255)
    static let healthGreen = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let healthGreenText = Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4C / 255)
    static let warningOrange = Color(red: 0xEA / 255, green: 0x8A / 255, blue: 0x1E / 255)
    static let warningBackground = Color(red: 0xFF / 255, green: 0xF8 / 255, blue: 0xEC / 255)
    static let warningBorder = Color(red: 0xFF / 255, green: 0xE8 / 255, blue: 0xC2 / 255)
    static let destructiveStart = Color(red: 0xFF / 255, green: 0x6E / 255, blue: 0x5A / 255)
    static let destructiveEnd = Color(red: 0xFF / 255, green: 0x3C / 255, blue: 0x32 / 255)
    static let textPrimary = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x1B / 255)
    static let textSecondary = Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8E / 255)
    static let textTertiary = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0xA0 / 255)
    static let trackBackground = Color(red: 0xEE / 255, green: 0xF0 / 255, blue: 0xF3 / 255)
    static let divider = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xF1 / 255)

    static let accentGradient = LinearGradient(
        colors: [accentGradientStart, accentGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let destructiveGradient = LinearGradient(
        colors: [destructiveStart, destructiveEnd], startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let dashboardBackground = RadialGradient(
        colors: [Color(red: 0xEE / 255, green: 0xF4 / 255, blue: 1), .white],
        center: .top, startRadius: 0, endRadius: 420
    )

    // MARK: Corner radii
    static let radiusWindow: CGFloat = 14
    static let radiusCard: CGFloat = 12
    static let radiusRow: CGFloat = 11
    static let radiusChip: CGFloat = 8

    // MARK: Sizes
    static let railWidth: CGFloat = 66
    static let logoTileSize: CGFloat = 36
    static let moduleTileSize: CGFloat = 44
    static let dashboardRingSize: CGFloat = 206
    static let cleaningRingSize: CGFloat = 132
    static let statusColumnWidth: CGFloat = 220
}
