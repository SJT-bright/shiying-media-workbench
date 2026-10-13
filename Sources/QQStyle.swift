import SwiftUI
import AppKit

// 拾影公共样式层：由 QQ排程助手的原生 SwiftUI 主题迁移而来。
// 来源（只读参考，未修改、未运行）：
//   related-project/Sources/Theme.swift  SHA256 80ad0120be6f8852646c1f7bc8a63e9f0d6530cc14b68643639d2f5ec6978b9b
//   related-project/Sources/App.swift    NavRow:1735 / NavRowLift:1786 / sidebar:1497 / footerBar:1684
// 名称一律加 QQ 前缀，避免与拾影 App.swift 已有的 Surface/Pill/accent/card/muted 冲突。
// 刻意不含 ClickFX（音效+触感）、NSEvent 全局监听、PulseDot/PermissionLight 等静止态循环动画。

// MARK: - 色板

/// 颜色保留原有语义，常用强调色随外观调整，保证浅色玻璃上的文字可读。
enum QQTheme {
    static let indigo = Color(red: 0.35, green: 0.30, blue: 0.96)
    static let violet = Color(red: 0.58, green: 0.29, blue: 0.96)
    static let mint   = adaptive(light: (0.02, 0.39, 0.34), dark: (0.47, 0.88, 0.80))
    static let blue   = adaptive(light: (0.08, 0.31, 0.64), dark: (0.44, 0.68, 0.97))
    static let cyan   = adaptive(light: (0.02, 0.36, 0.48), dark: (0.44, 0.82, 0.95))
    static let teal   = Color(red: 0.08, green: 0.66, blue: 0.60)
    static let green  = Color(red: 0.16, green: 0.72, blue: 0.46)
    static let amber  = adaptive(light: (0.52, 0.31, 0.02), dark: (0.98, 0.66, 0.14))
    static let orange = adaptive(light: (0.70, 0.25, 0.04), dark: (0.97, 0.45, 0.14))
    static let rose   = Color(red: 0.95, green: 0.27, blue: 0.45)
    static let pink   = Color(red: 0.93, green: 0.31, blue: 0.68)
    static let slate  = Color(red: 0.40, green: 0.44, blue: 0.53)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    static let brand   = LinearGradient(colors: [mint, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandUp = LinearGradient(colors: [mint, cyan], startPoint: .top, endPoint: .bottom)
    static let cool    = LinearGradient(colors: [mint, cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warm    = LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let danger  = LinearGradient(colors: [rose, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = LinearGradient(colors: [teal, green], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let steel   = LinearGradient(colors: [slate, slate.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 页面色。主操作走薄荷青到青，爆款指标另用 amber。
    static func gradient(for key: String) -> LinearGradient {
        switch key {
        case "博主采集":                    return brand
        case "新建下载", "home", "compose": return cool
        case "批量收集":                    return cool
        case "收集文件夹", "assets":        return success
        case "下载记录", "history":         return success
        case "使用说明", "settings":        return steel
        case "queue":                       return warm
        case "recipients":                  return LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:                            return brand
        }
    }
}

// MARK: - 明暗自适应表面

/// 迁移自 Theme.swift:45-65 的 `Surface`。改名是因为拾影 App.swift:161 已有泛型 `Surface<Content>`。
struct QQPalette {
    let scheme: ColorScheme
    init(_ scheme: ColorScheme) { self.scheme = scheme }
    var dark: Bool { scheme == .dark }

    // 色值仅用于浅染色/占位；实体玻璃由 ShiyingGlassSurface 绘制。
    var page: Color { .clear }
    var card: Color { dark ? .white.opacity(0.035) : .white.opacity(0.12) }
    var inset: Color { dark ? .black.opacity(0.05) : .white.opacity(0.08) }
    var highlight: Color { .white.opacity(dark ? 0.36 : 0.75) }
    var edge: Color { .white.opacity(dark ? 0.16 : 0.35) }
    var shadow: Color { .black.opacity(dark ? 0.20 : 0.10) }
    var shadowSoft: Color { .black.opacity(dark ? 0.10 : 0.05) }
    var hairline: Color { .white.opacity(dark ? 0.12 : 0.30) }

}

// MARK: - 立体卡片

/// 迁移自 Theme.swift:68-120 的 `DepthSurface`。内容在底层，视觉全部通过 background/overlay 叠出来。
/// hoverable/inset 是契约之外的可省参数，调用 `QQDepthSurface(radius:padding:accent:) { }` 不受影响。
struct QQDepthSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var radius: CGFloat = 22
    var padding: CGFloat = 20
    var accent: Color? = nil
    var hoverable: Bool = false
    var inset: Bool = false
    private let content: Content
    @State private var pointer = QQPointerState()

    init(radius: CGFloat = 22,
         padding: CGFloat = 20,
         accent: Color? = nil,
         hoverable: Bool = false,
         inset: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.padding = padding
        self.accent = accent
        self.hoverable = hoverable
        self.inset = inset
        self.content = content()
    }

    /// 默认不跟手。卡片里通常还有按钮，抬起整张卡会把内部 Hover 一起带走。
    private var lifted: Bool {
        hoverable && pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: false)
    }

    var body: some View {
        // 必须显式套一层 VStack：SwiftUI 会把修饰符逐个作用到多子视图闭包的每个子视图上，
        // 那样一次调用会画出多张卡片。
        // 布局容器不缩放、不位移。只让玻璃底在内部起伏，卡片里的按钮命中区才不会跟着抖。
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ShiyingGlassSurface(radius: radius, tint: (accent ?? .clear).opacity(0.04), inset: inset)
                    .scaleEffect(QQMotion.controlScale(showsLift: lifted, showsPress: false, hoverScale: 1.012, pressedScale: 1))
                    .offset(y: QQMotion.controlOffsetY(showsLift: lifted, showsPress: false, pressedOffset: 0))
                    .animation(QQMotion.hoverAnimation(reduceMotion: reduceMotion), value: lifted)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { inside in
                guard hoverable else { return }
                var copy = pointer
                copy.pointer(inside: inside, isEnabled: isEnabled)
                pointer = copy
            }
            .onChange(of: isEnabled) { _, _ in
                var copy = pointer
                copy.resetForEnvironmentChange()
                pointer = copy
            }
            .onChange(of: reduceMotion) { _, _ in
                var copy = pointer
                copy.resetForEnvironmentChange()
                pointer = copy
            }
    }
}

// MARK: - 玻璃图标块

/// 原生 SF Symbols 层级渲染，明亮彩色字形与轻薄底色，避免暗色厚底座。
struct QQIconTile: View {
    let symbol: String
    var size: CGFloat = 42
    var gradient: LinearGradient = QQTheme.brand
    @Environment(\.colorScheme) private var scheme

    init(symbol: String, size: CGFloat = 42, gradient: LinearGradient = QQTheme.brand) {
        self.symbol = symbol
        self.size = size
        self.gradient = gradient
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(QQTheme.blue.opacity(scheme == .dark ? 0.10 : 0.07))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.59, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(gradient)
            }
            .frame(width: size, height: size)
    }
}

// MARK: - 小标签

/// 状态标签沿用 Pill 接口，统一使用原生玻璃与轻染色。
/// 「类别」靠形态区分，「个体」靠颜色 + 图标区分，同一行里任意两个标签都不会重样：
///   .tinted   彩色玻璃（状态 / 画质等强语义标签，契约默认档）
///   .neutral  中性玻璃 + 彩色图标（元信息标签，底栏那一排用的就是它）
///   .emphasis 加强玻璃染色（需要跳出来的提示）
struct QQPill: View {
    enum Variant { case tinted, neutral, emphasis }

    let text: String
    var tint: Color = QQTheme.cyan
    var symbol: String? = nil
    var variant: Variant = .tinted
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    init(text: String,
         tint: Color = QQTheme.cyan,
         symbol: String? = nil,
         variant: Variant = .tinted,
         compact: Bool = false) {
        self.text = text
        self.tint = tint
        self.symbol = symbol
        self.variant = variant
        self.compact = compact
    }

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: compact ? 3.5 : 4.5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 8.5 : 9, weight: .bold))
                    .foregroundStyle(iconColor)
                    .shadow(color: iconGlow, radius: 1.2, x: 0, y: 0.5)
            }
            Text(text)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, compact ? 6.5 : 8.5)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background {
            ShiyingGlassSurface(radius: 100, tint: tint.opacity(variant == .emphasis ? 0.24 : 0.08), inset: true)
        }
        .fixedSize()
    }

    private var textColor: Color {
        switch variant {
        case .tinted:   return Color.primary
        case .neutral:  return Color.primary.opacity(dark ? 0.80 : 0.65)
        case .emphasis: return Color.primary
        }
    }

    private var iconColor: Color {
        switch variant {
        case .emphasis: return Color.primary
        default:        return tint
        }
    }

    private var iconGlow: Color {
        variant == .emphasis ? Color.black.opacity(0.25) : tint.opacity(0.35)
    }

    private var glow: Color {
        switch variant {
        case .tinted:   return Color.primary.opacity(dark ? 0.22 : 0.14)
        case .neutral:  return tint.opacity(dark ? 0.14 : 0.10)
        case .emphasis: return tint.opacity(dark ? 0.40 : 0.28)
        }
    }
}

// MARK: - 按压涟漪

/// 迁移自 Theme.swift:545-563 的 `RippleDisc`。progress 0→1 画一圈从中心扩散并淡出的圆盘。
/// progress 必须是线性式：写成 `progress < 1 ? … : 0` 会让动画两端都取到 0，涟漪就再也扩不出来。
/// 静止时 scale 为 0，圆本身没有面积。
private struct QQPressRippleDisc: View {
    var progress: CGFloat
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            // 取对角线刚好盖住四个角；用 1.45×长边在宽按钮上会画出一个面积翻倍的巨圆。
            let side = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
            Circle()
                .fill(color)
                .frame(width: side, height: side)
                .scaleEffect(progress)
                .opacity((1 - progress) * 0.45)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// 迁移自 Theme.swift:567-598 的 `RippleLayer`，只保留视觉层。
/// 来源在此调用 ClickFX.play（系统音效 + 触感）并受 UserDefaults 开关控制，本次迁移按契约整体舍弃。
/// 放在按钮自己的 background 闭包里，所以能被按钮圆角裁住，sheet / popover 里的按钮同样生效。
private struct QQPressRipple: View {
    static let duration: TimeInterval = 0.42

    var highlight: Bool
    var color: Color = .white
    var radius: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            color.opacity(highlight ? (reduceMotion ? 0.10 : 0.14) : 0)
            if !reduceMotion {
                QQPressRippleDisc(progress: progress, color: color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: highlight ? 0.08 : 0.20), value: highlight)
        .onChange(of: highlight) { _, down in
            guard down else {
                progress = 0
                return
            }
            // 只在按下沿读取当前事件。鼠标左键不扩圈；之后的重绘不能把已经开始的键盘涟漪清掉。
            // 缓存一次。keyCode 若作为实参直接读，类型判断还没跑，鼠标事件就会抛异常。
            let event = NSApp.currentEvent
            let fields = qqButtonRippleEvent(event)
            guard QQMotion.shouldDrawButtonRipple(
                isEnabled: true,
                reduceMotion: reduceMotion,
                eventType: fields.type,
                keyCode: fields.keyCode,
                characters: fields.characters
            ) else { return }
            restart()
        }
        .onChange(of: reduceMotion) { _, _ in progress = 0 }
    }

    private func restart() {
        guard !reduceMotion else {
            progress = 0
            return
        }
        progress = 0
        // 同一轮里先归零再动画会被合并成一次赋值，推到下一个 runloop 才真的从中心扩出来。
        DispatchQueue.main.async { withAnimation(.easeOut(duration: Self.duration)) { progress = 1 } }
    }
}

/// 按钮涟漪只看键盘空格/回车。先判断类型，再读键盘属性；鼠标和其它事件不读 keyCode。
struct QQButtonRippleEvent: Equatable {
    var type: NSEvent.EventType?
    var keyCode: UInt16?
    var characters: String?
}

func qqButtonRippleEvent(_ event: NSEvent?) -> QQButtonRippleEvent {
    guard let event else {
        return QQButtonRippleEvent(type: nil, keyCode: nil, characters: nil)
    }
    let type = event.type
    guard type == .keyDown || type == .keyUp else {
        return QQButtonRippleEvent(type: type, keyCode: nil, characters: nil)
    }
    return QQButtonRippleEvent(
        type: type,
        keyCode: event.keyCode,
        characters: event.charactersIgnoringModifiers
    )
}

// MARK: - 按钮按压 + 悬停

/// 悬停抬起、按下轻压。trackHover 为假时不安装 onHover，避免和外侧再叠一层。
private struct QQButtonPress: ViewModifier {
    var pressed: Bool
    var enabled: Bool
    var trackHover: Bool
    var pressedScale: CGFloat
    var pressedOffset: CGFloat
    var hoverScale: CGFloat
    var pressDamping: CGFloat
    @Binding var pointer: QQPointerState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsLift: Bool {
        trackHover && pointer.showsLift(isEnabled: enabled, reduceMotion: reduceMotion, pressed: pressed)
    }

    private var showsPress: Bool { pressed && enabled && !reduceMotion }

    func body(content: Content) -> some View {
        let moved = content
            .scaleEffect(QQMotion.controlScale(
                showsLift: showsLift,
                showsPress: showsPress,
                hoverScale: hoverScale,
                pressedScale: pressedScale
            ))
            .offset(y: QQMotion.controlOffsetY(
                showsLift: showsLift,
                showsPress: showsPress,
                pressedOffset: pressedOffset
            ))
            .animation(reduceMotion ? nil : .spring(response: QQMotion.hoverResponse, dampingFraction: QQMotion.hoverDamping), value: showsLift)
            .animation(reduceMotion ? nil : .spring(response: QQMotion.pressResponse, dampingFraction: QQMotion.pressDamping), value: showsPress)
            .onChange(of: enabled) { _, _ in
                var copy = pointer
                copy.resetForEnvironmentChange()
                pointer = copy
            }
            .onChange(of: reduceMotion) { _, _ in
                var copy = pointer
                copy.resetForEnvironmentChange()
                pointer = copy
            }
        if trackHover {
            ZStack { moved }.contentShape(Rectangle()).onHover { inside in
                var copy = pointer
                copy.pointer(inside: inside, isEnabled: enabled)
                pointer = copy
            }
        } else {
            ZStack { moved }.contentShape(Rectangle())
        }
    }
}

/// 玻璃主按钮。保留原有 DepthButtonStyle 的按压与悬停接口。
/// 来源没有禁用态，这里补上：禁用时去饱和 + 减不透明度 + 收掉彩色投影，
/// 且不再画涟漪、不再响应按压与悬停。
struct QQDepthButtonStyle: ButtonStyle {
    var gradient: LinearGradient = QQTheme.brand
    var tint: Color = QQTheme.cyan
    var compact: Bool = false

    init(gradient: LinearGradient = QQTheme.brand, tint: Color = QQTheme.cyan, compact: Bool = false) {
        self.gradient = gradient
        self.tint = tint
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        QQDepthButtonBody(configuration: configuration, gradient: gradient, tint: tint, compact: compact)
    }
}

private struct QQDepthButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var gradient: LinearGradient
    var tint: Color
    var compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = QQPointerState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 100, style: .continuous)
        let pressed = configuration.isPressed && isEnabled
        let lifted = pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: pressed)
        configuration.label
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 12 : 17)
            .padding(.vertical, compact ? 6.5 : 9)
            .frame(minHeight: compact ? 32 : 36)
            .background {
                ShiyingGlassSurface(radius: 100, tint: tint.opacity(isEnabled ? 0.22 : 0.03), control: true)
                    .overlay { shape.strokeBorder(tint.opacity(pointer.hovering && isEnabled ? 0.70 : 0.25), lineWidth: 1.1) }
                    .overlay {
                        if isEnabled { QQPressRipple(highlight: pressed, color: .white, radius: 100) }
                    }
                    .shadow(color: lifted ? tint.opacity(0.16) : .clear, radius: 10, y: 4)
            }
            .saturation(isEnabled ? 1 : 0.30)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(shape)
            .modifier(QQButtonPress(
                pressed: pressed,
                enabled: isEnabled,
                trackHover: true,
                pressedScale: 0.97,
                pressedOffset: 1,
                hoverScale: QQMotion.hoverScale,
                pressDamping: 0.66,
                pointer: $pointer
            ))
    }
}

/// 次级（描边玻璃）按钮。迁移自 Theme.swift:669-704 的 `SoftButtonStyle`。
/// 禁用态同 `QQDepthButtonStyle`：去饱和 + 减不透明度 + 收投影，无涟漪无按压反馈。
struct QQSoftButtonStyle: ButtonStyle {
    var tint: Color = QQTheme.cyan
    var selected = false

    init(tint: Color = QQTheme.cyan, selected: Bool = false) { self.tint = tint; self.selected = selected }

    func makeBody(configuration: Configuration) -> some View {
        QQSoftButtonBody(configuration: configuration, tint: tint, selected: selected)
    }
}

private struct QQSoftButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var tint: Color
    var selected: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.font) private var inheritedFont
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = QQPointerState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 100, style: .continuous)
        let pressed = configuration.isPressed && isEnabled
        let lifted = pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: pressed)
        configuration.label
            // 磅值交给调用方（大字号下才会变），字重留在这里，否则默认档会变细。
            .font((inheritedFont ?? .system(size: 13)).weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background {
                ShiyingGlassSurface(radius: 100, tint: tint.opacity(selected ? 0.18 : (lifted ? 0.08 : 0.02)), inset: true, control: true)
                    .overlay {
                        if selected || pointer.hovering && isEnabled {
                            shape.strokeBorder(tint.opacity(selected ? 0.60 : 0.65), lineWidth: 1.1)
                        }
                    }
                    .overlay {
                        if isEnabled { QQPressRipple(highlight: pressed, color: tint, radius: 100) }
                    }
            }
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? 1 : 0.50)
            .contentShape(shape)
            .modifier(QQButtonPress(
                pressed: pressed,
                enabled: isEnabled,
                trackHover: true,
                pressedScale: 0.975,
                pressedOffset: 0.6,
                hoverScale: QQMotion.hoverScale,
                pressDamping: 0.68,
                pointer: $pointer
            ))
    }
}

/// 无边框按钮的点击反馈。迁移自 Theme.swift:602-612 的 `GhostPressButtonStyle`。
/// 已带玻璃的行只画 label；独立小按钮显式选择玻璃背景，保留涟漪和按压缩放。
/// 禁用时只降不透明度（跟系统控件的禁用观感一致），不画涟漪、不缩放。
struct QQGhostPressStyle: ButtonStyle {
    var tint: Color = QQTheme.cyan
    var radius: CGFloat = 10
    var glass = false
    fileprivate var hoverLift: Bool = true

    init(tint: Color = QQTheme.cyan, radius: CGFloat = 10, glass: Bool = false) {
        self.tint = tint
        self.radius = radius
        self.glass = glass
        self.hoverLift = true
    }

    fileprivate init(tint: Color = QQTheme.cyan, radius: CGFloat = 10, hoverLift: Bool) {
        self.tint = tint
        self.radius = radius
        self.hoverLift = hoverLift
    }

    func makeBody(configuration: Configuration) -> some View {
        QQGhostPressBody(configuration: configuration, tint: tint, radius: radius, hoverLift: hoverLift, glass: glass)
    }
}

private struct QQGhostPressBody: View {
    var configuration: ButtonStyleConfiguration
    var tint: Color
    var radius: CGFloat
    var hoverLift: Bool
    var glass: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = QQPointerState()

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        let lifted = hoverLift && pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: pressed)
        configuration.label
            .padding(glass ? 6 : 0)
            .frame(minWidth: glass ? 32 : nil, minHeight: glass ? 32 : nil)
            .background {
                if glass { ShiyingGlassSurface(radius: radius, tint: tint.opacity(0.04), control: true) }
            }
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if isEnabled {
                    QQPressRipple(highlight: pressed, color: tint, radius: radius)
                }
            }
            .overlay {
                if hoverLift && pointer.hovering && isEnabled {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(tint.opacity(0.65), lineWidth: 1.1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: lifted ? tint.opacity(0.28) : .clear, radius: lifted ? 8 : 0, y: lifted ? 4 : 0)
            .modifier(QQButtonPress(
                pressed: pressed,
                enabled: isEnabled,
                trackHover: hoverLift,
                pressedScale: 0.975,
                pressedOffset: 0.8,
                hoverScale: QQMotion.hoverScale,
                pressDamping: 0.66,
                pointer: $pointer
            ))
    }
}

// MARK: - 侧栏导航行

/// 迁移自 QQ App.swift:1735-1800 的 `NavRow` + `NavRowLift`。
/// 来源按 `NavItem` 取标题与渐变，这里改成契约的扁平参数：渐变量由 `title` 经
/// `QQTheme.gradient(for:)` 推导，未识别的页面名回落到 brand，语义与来源一致。
struct QQNavRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var badge: Int? = nil
    var prominent: Bool = false
    let action: () -> Void

    @State private var pointer = QQPointerState()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    init(title: String,
         subtitle: String,
         symbol: String,
         selected: Bool,
         badge: Int? = nil,
         prominent: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.selected = selected
        self.badge = badge
        self.prominent = prominent
        self.action = action
    }

    private var tone: Color { prominent ? QQTheme.mint : QQTheme.cyan }

    private var lifted: Bool {
        pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: false)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
        Button(action: action) {
            HStack(spacing: 11) {
                QQIconTile(symbol: symbol, size: prominent ? 30 : 27, gradient: QQTheme.gradient(for: title))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: prominent ? 14 : 13, weight: (selected || prominent) ? .semibold : .medium))
                        .foregroundStyle(Color.primary)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.primary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .shiyingGlass(radius: 100, tint: tone.opacity(0.18), inset: true)
                        .shadow(color: tone.opacity(0.4), radius: 3, y: 1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, prominent ? 10 : 9)
            .background {
                ShiyingGlassSurface(radius: 18, tint: selected ? tone.opacity(0.30) : .clear, inset: !selected)
                    .opacity(selected || pointer.hovering ? 1 : 0.65)
                    .overlay {
                        if selected || pointer.hovering && isEnabled {
                            shape.strokeBorder(tone.opacity(selected ? 0.55 : 0.75), lineWidth: 1.1)
                        }
                    }
            }
            .contentShape(shape)
        }
        .buttonStyle(QQGhostPressStyle(tint: tone, radius: 18, hoverLift: false))
        .scaleEffect(QQMotion.controlScale(showsLift: lifted, showsPress: false, hoverScale: QQMotion.hoverScale, pressedScale: 1))
        .offset(y: QQMotion.controlOffsetY(showsLift: lifted, showsPress: false, pressedOffset: 0))
        .shadow(color: lifted ? tone.opacity(0.30) : .clear, radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
        .shadow(color: lifted ? Color.black.opacity(0.12) : .clear, radius: lifted ? 2 : 0, y: 1)
        .animation(reduceMotion ? nil : .spring(response: QQMotion.hoverResponse, dampingFraction: QQMotion.hoverDamping), value: lifted)
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80), value: selected)
        }
        .contentShape(shape)
        .onHover { inside in
            var copy = pointer
            copy.pointer(inside: inside, isEnabled: isEnabled)
            pointer = copy
        }
        .onChange(of: isEnabled) { _, _ in
            var copy = pointer
            copy.resetForEnvironmentChange()
            pointer = copy
        }
        .onChange(of: reduceMotion) { _, _ in
            var copy = pointer
            copy.resetForEnvironmentChange()
            pointer = copy
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let badge, badge > 0 else { return "\(title)，\(subtitle)" }
        return "\(title)，\(subtitle)，\(badge) 项"
    }
}
