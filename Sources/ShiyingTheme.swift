import SwiftUI

/// 用户明确选择昼夜；保留夜间作为已有版本的默认外观。
enum ShiyingTheme: String, CaseIterable, Identifiable {
    case day, night

    static let storageKey = "shiyingAppearance"
    static var defaults: UserDefaults {
        if CommandLine.arguments.contains("--test-mode") {
            return UserDefaults(suiteName: "com.local.shiying.testing")!
        }
        return .standard
    }
    static func resolve(_ rawValue: String) -> ShiyingTheme { ShiyingTheme(rawValue: rawValue) ?? .night }
    var id: String { rawValue }
    var title: String { self == .day ? "白天" : "黑夜" }
    var symbol: String { self == .day ? "sun.max.fill" : "moon.stars.fill" }
    var colorScheme: ColorScheme { self == .day ? .light : .dark }
}

/// 可以放入侧栏或标题区。两个按钮共用主窗口的持久偏好。
struct ShiyingThemePicker: View {
    @AppStorage(ShiyingTheme.storageKey, store: ShiyingTheme.defaults)
    private var appearance = ShiyingTheme.night.rawValue

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ShiyingTheme.allCases) { theme in
                Button { appearance = theme.rawValue } label: {
                    Label(theme.title, systemImage: theme.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QQSoftButtonStyle(tint: theme == .day ? QQTheme.amber : QQTheme.blue,
                                               selected: appearance == theme.rawValue))
                .accessibilityLabel("\(theme.title)模式")
                .accessibilityAddTraits(appearance == theme.rawValue ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("外观")
    }
}
