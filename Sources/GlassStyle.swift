import SwiftUI
import AppKit

/// 复用既有两张城市照片；主题同时切换壁纸、文字与玻璃外观。
struct ShiyingWallpaper: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let nightImage: NSImage? = Bundle.main.url(forResource: "GlassWallpaper", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    private static let dayImage: NSImage? = Bundle.main.url(forResource: "GlassWallpaperDay", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                scheme == .dark ? Color(red: 0.08, green: 0.14, blue: 0.21) : Color(red: 0.86, green: 0.93, blue: 0.98)
                if let image = scheme == .dark ? Self.nightImage : Self.dayImage {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .saturation(0.92).blur(radius: 1.5)
                }
                if scheme == .dark {
                    Color.black.opacity(reduceTransparency ? 0.58 : 0.10)
                    LinearGradient(colors: [.black.opacity(0.04), .clear, .black.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom)
                } else { Color.white.opacity(reduceTransparency ? 0.65 : 0.23) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 所有表面统一磨砂材质和柔和底色；只绘制背景，不拦截输入。
struct ShiyingGlassSurface: View {
    var radius: CGFloat = 22
    var tint: Color = .clear
    var inset = false
    var control = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var solid: Bool { reduceTransparency || contrast == .increased }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        material
            .overlay {
                shape.strokeBorder(scheme == .dark ? Color.white.opacity(inset ? 0.18 : 0.14) : Color.black.opacity(0.10),
                                   lineWidth: solid ? 1.2 : 0.8)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.16 : 0.08), radius: inset ? 2 : 8, y: inset ? 1 : 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var material: some View {
        if solid {
            shape.fill(scheme == .dark ? Color(red: 0.11, green: 0.17, blue: 0.23) : Color(red: 0.91, green: 0.95, blue: 0.98))
                .overlay { shape.fill(tint.opacity(0.12)) }
        } else {
            shape.fill(.regularMaterial)
                .overlay {
                    // 稳定文字对比，避免城市灯光透过表面干扰阅读。
                    shape.fill(scheme == .dark ? Color(red: 0.07, green: 0.10, blue: 0.15) : Color.white)
                        .opacity(control ? 0.48 : (inset ? 0.44 : 0.40))
                }
                .overlay { shape.fill(tint) }
        }
    }
}

struct ShiyingGlassFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        ShiyingGlassField(configuration: configuration)
    }
}

private struct ShiyingGlassField<Label: View>: View {
    var configuration: TextField<Label>
    @FocusState private var focused: Bool

    var body: some View {
        configuration.textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background { ShiyingGlassSurface(radius: 12, inset: true) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? QQTheme.blue.opacity(0.65) : .clear, lineWidth: 1.25)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 菜单沿用系统选项与键盘行为，触发区域与其它输入框使用同一玻璃材质。
struct ShiyingGlassMenu<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var values: [Value]
    var display: (Value) -> String

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    if value == selection { Label(display(value), systemImage: "checkmark") }
                    else { Text(display(value)) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(display(selection)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ShiyingGlassSurface(radius: 12, inset: true, control: true) }
        .accessibilityLabel(title).accessibilityValue(display(selection))
        .qqControlMotion(tint: QQTheme.cyan)
    }
}

extension View {
    func shiyingGlass(radius: CGFloat = 16, tint: Color = .clear, inset: Bool = false) -> some View {
        background { ShiyingGlassSurface(radius: radius, tint: tint, inset: inset) }
    }
}
