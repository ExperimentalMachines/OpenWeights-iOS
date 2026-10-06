import SwiftUI

enum OWTheme {
    static func preferredColorScheme(_ appearance: String) -> ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    static let lime = Color(hex: 0xE0FF4F)
    static let ink = Color(hex: 0x052B42)
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x0D0E10)
    static let raised = adaptive(light: 0xF4F5F3, dark: 0x161719)
    static let text = adaptive(light: 0x052B42, dark: 0xF5F6F3)
    static let secondary = adaptive(light: 0x52555B, dark: 0xA2A4AB)
    static let outline = adaptive(light: 0x7C7F86, dark: 0x6E7178)
    static let signal = adaptive(light: 0x27745F, dark: 0x3BA88F)
    static let danger = adaptive(light: 0xC23D41, dark: 0xFF6166)
    static func interface(_ size: CGFloat = 16) -> Font { .custom("HankenGrotesk-Regular", size: size, relativeTo: .body) }
    static func metric(_ size: CGFloat = 12) -> Font { .custom("GeistMono-Regular", size: size, relativeTo: .caption) }
    static func display(_ size: CGFloat = 24) -> Font { .custom("SchibstedGrotesk-Regular", size: size, relativeTo: .title) }
    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light)) })
    }
}
extension Color {
    init(hex: UInt) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
struct OWActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(OWTheme.interface()).foregroundStyle(OWTheme.ink)
            .padding(.horizontal, 18).frame(minHeight: 44).background(OWTheme.lime, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
