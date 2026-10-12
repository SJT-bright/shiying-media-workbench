import SwiftUI
import AppKit

// 公共动效。窗口涟漪只用本进程、本窗口的一个 local monitor，调用方不要再挂第二层。
// qqControlMotion 的起伏只走视觉变换；悬停和点击留在未移动的玻璃轮廓上。

enum QQMotion {
    static let hoverLift: CGFloat = 3.5
    static let hoverScale: CGFloat = 1.016
    static let revealDuration: TimeInterval = 0.32
    static let revealReducedDuration: TimeInterval = 0.30
    static let rippleDuration: TimeInterval = 0.54
    static let rippleReducedDuration: TimeInterval = 0.28
    static let rippleLimit = 4

    /// 统一弹簧。悬停阻尼取高，减少过冲；按压更短。集成方可以改这四个数。
    static let hoverResponse: Double = 0.30
    static let hoverDamping: Double = 0.88
    static let pressResponse: Double = 0.18
    static let pressDamping: Double = 0.90

    static func hoverAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: hoverResponse, dampingFraction: hoverDamping)
    }

    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: pressResponse, dampingFraction: pressDamping)
    }

    static func controlOffsetY(showsLift: Bool, showsPress: Bool, pressedOffset: CGFloat) -> CGFloat {
        if showsPress { return pressedOffset }
        if showsLift { return -hoverLift }
        return 0
    }

    static func controlScale(showsLift: Bool, showsPress: Bool, hoverScale: CGFloat, pressedScale: CGFloat) -> CGFloat {
        if showsPress { return pressedScale }
        if showsLift { return hoverScale }
        return 1
    }

    /// 键盘空格/回车才画按钮中心涟漪。鼠标左键交给窗口层，避免两圈。
    static func shouldDrawButtonRipple(
        isEnabled: Bool,
        reduceMotion: Bool,
        eventType: NSEvent.EventType?,
        keyCode: UInt16?,
        characters: String? = nil
    ) -> Bool {
        guard isEnabled, !reduceMotion, let eventType else { return false }
        switch eventType {
        case .keyDown, .keyUp:
            if keyCode == 49 || keyCode == 36 || keyCode == 76 { return true }
            if let characters {
                return characters == " " || characters == "\r" || characters == "\n"
            }
            return false
        default:
            return false
        }
    }

    static func revealOffsetY(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return (1 - min(1, max(0, progress))) * 10
    }

    static func revealBlur(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return (1 - min(1, max(0, progress))) * 9
    }

    static func shouldRecordClick(
        appIsActive: Bool,
        eventWindowIsTarget: Bool,
        contentHeight: CGFloat,
        eventType: NSEvent.EventType
    ) -> Bool {
        appIsActive && eventWindowIsTarget && contentHeight > 1 && eventType == .leftMouseDown
    }

    /// 涟漪画在监听宿主视图里。宿主还没进目标窗口，或 bounds 高度不足，就不记。
    static func shouldRecordHostClick(
        hostInWindow: Bool,
        hostHeight: CGFloat,
        appIsActive: Bool,
        eventWindowIsTarget: Bool,
        eventType: NSEvent.EventType
    ) -> Bool {
        hostInWindow && shouldRecordClick(
            appIsActive: appIsActive,
            eventWindowIsTarget: eventWindowIsTarget,
            contentHeight: hostHeight,
            eventType: eventType
        )
    }

    /// 非翻转视图的底边是局部 (0, 0)；翻转视图的底边是局部 (0, height)。转换闭包把该点变到窗口坐标。
    static func contentBottomLeft(isFlipped: Bool, height: CGFloat, convert: (CGPoint) -> CGPoint) -> CGPoint {
        convert(isFlipped ? CGPoint(x: 0, y: height) : .zero)
    }

    /// locationInWindow 与 content 底边都在窗口坐标（y 向上）。SwiftUI 用 y 向下，只翻一次。
    static func swiftUIClickPoint(
        locationInWindow: CGPoint,
        contentBottomLeftInWindow: CGPoint,
        contentHeight: CGFloat
    ) -> CGPoint {
        let localX = locationInWindow.x - contentBottomLeftInWindow.x
        let localYFromBottom = locationInWindow.y - contentBottomLeftInWindow.y
        return CGPoint(x: localX, y: contentHeight - localYFromBottom)
    }

    /// 用宿主视图自己的高度和它转到窗口坐标的底边。不要用 contentView 的高度。
    static func hostClickPoint(
        locationInWindow: CGPoint,
        hostIsFlipped: Bool,
        hostHeight: CGFloat,
        convertToWindow: (CGPoint) -> CGPoint
    ) -> CGPoint? {
        guard hostHeight > 1 else { return nil }
        let bottomLeft = contentBottomLeft(isFlipped: hostIsFlipped, height: hostHeight, convert: convertToWindow)
        return swiftUIClickPoint(
            locationInWindow: locationInWindow,
            contentBottomLeftInWindow: bottomLeft,
            contentHeight: hostHeight
        )
    }

    static func appendRipple<T>(_ ripples: [T], _ item: T, limit: Int = rippleLimit) -> [T] {
        var next = ripples
        if next.count >= limit {
            next.removeFirst(next.count - limit + 1)
        }
        next.append(item)
        return next
    }
}

struct QQPointerState: Equatable {
    var hovering = false
    var pressed = false

    mutating func pointer(inside: Bool, isEnabled: Bool) {
        hovering = inside && isEnabled
    }

    mutating func notePress(_ isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) {
        pressed = isPressed && isEnabled && !reduceMotion
    }

    mutating func resetForEnvironmentChange() {
        hovering = false
        pressed = false
    }

    func showsLift(isEnabled: Bool, reduceMotion: Bool, pressed: Bool) -> Bool {
        hovering && isEnabled && !pressed && !reduceMotion
    }

    func showsPress(isEnabled: Bool, reduceMotion: Bool) -> Bool {
        self.pressed && isEnabled && !reduceMotion
    }
}

extension View {
    func qqControlMotion(tint: Color = QQTheme.indigo, radius: CGFloat = 12) -> some View {
        modifier(QQControlMotionModifier(tint: tint, radius: radius))
    }
}

private struct QQControlMotionModifier: ViewModifier {
    var tint: Color
    var radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var pointer = QQPointerState()
    /// 退出代数。同一轮里的 false→true 会作废尚未提交的退出，避免弹簧被来回打断。
    @State private var hoverExit = QQHoverExitGate()

    func body(content: Content) -> some View {
        let palette = QQPalette(scheme)
        let highlight = pointer.hovering && isEnabled
        let lifted = pointer.showsLift(isEnabled: isEnabled, reduceMotion: reduceMotion, pressed: pointer.pressed)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let scale = QQMotion.controlScale(
            showsLift: lifted,
            showsPress: false,
            hoverScale: QQMotion.hoverScale,
            pressedScale: 1
        )
        let offsetY = QQMotion.controlOffsetY(showsLift: lifted, showsPress: false, pressedOffset: 0)

        content
            .overlay {
                shape
                    .fill(highlight ? tint.opacity(scheme == .dark ? 0.045 : 0.035) : Color.clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                tint.opacity(highlight ? 0.80 : 0),
                                tint.opacity(highlight ? 0.35 : 0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.25
                    )
                    .allowsHitTesting(false)
            }
            // 投影只画在轮廓上，半径固定。不对整块文字/输入框做 compositingGroup 或逐帧变半径的阴影。
            .background {
                shape
                    .fill(palette.shadow)
                    .blur(radius: 5)
                    .offset(y: 3)
                    .opacity(lifted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .visualEffect { effect, _ in
                effect
                    .scaleEffect(scale, anchor: .center)
                    .offset(y: offsetY)
            }
            .contentShape(shape)
            .animation(QQMotion.hoverAnimation(reduceMotion: reduceMotion), value: lifted)
            .animation(highlightAnimation, value: highlight)
            .animation(QQMotion.pressAnimation(reduceMotion: reduceMotion), value: pointer.pressed)
            .onHover { inside in
                receiveHover(inside)
            }
            .onChange(of: isEnabled) { _, _ in
                hoverExit.generation += 1
                resetPointer()
            }
            .onChange(of: reduceMotion) { _, _ in
                hoverExit.generation += 1
                resetPointer()
            }
            .onDisappear {
                hoverExit.generation += 1
            }
    }

    private var highlightAnimation: Animation? {
        if reduceMotion { return .easeOut(duration: 0.16) }
        return QQMotion.hoverAnimation(reduceMotion: false)
    }

    private func receiveHover(_ inside: Bool) {
        hoverExit.generation += 1
        let generation = hoverExit.generation
        let gate = hoverExit
        let enabled = isEnabled
        if inside || !enabled {
            applyHover(inside, enabled: enabled)
            return
        }
        // 只推迟到下一轮主队列。真正离开会提交；同一轮重新进入则取消，弹簧不被打断。
        DispatchQueue.main.async {
            guard generation == gate.generation else { return }
            applyHover(false, enabled: enabled)
        }
    }

    private func applyHover(_ inside: Bool, enabled: Bool) {
        var copy = pointer
        copy.pointer(inside: inside, isEnabled: enabled)
        guard copy != pointer else { return }
        pointer = copy
    }

    private func resetPointer() {
        var copy = pointer
        copy.resetForEnvironmentChange()
        guard copy != pointer else { return }
        pointer = copy
    }
}

/// 悬停退出的代数。用类保存，延迟提交时读到的是当前值，而不是调度当时的拷贝。
private final class QQHoverExitGate {
    var generation = 0
}

struct QQPageReveal<Content: View>: View {
    let pageID: String
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var generation = 0

    init(pageID: String, @ViewBuilder content: () -> Content) {
        self.pageID = pageID
        self.content = content()
    }

    var body: some View {
        content
            .opacity(Double(progress))
            .offset(y: QQMotion.revealOffsetY(progress: progress, reduceMotion: reduceMotion))
            .blur(radius: QQMotion.revealBlur(progress: progress, reduceMotion: reduceMotion))
            .onAppear { restart() }
            .onChange(of: pageID) { _, _ in restart() }
            .onChange(of: reduceMotion) { _, _ in
                generation += 1
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = 1 }
            }
    }

    private func restart() {
        generation += 1
        let token = generation
        let duration = reduceMotion ? QQMotion.revealReducedDuration : QQMotion.revealDuration
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = 0 }
        DispatchQueue.main.async {
            guard token == generation else { return }
            withAnimation(.easeOut(duration: duration)) {
                guard token == generation else { return }
                progress = 1
            }
        }
    }
}

final class QQRippleModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let point: CGPoint
        let duration: TimeInterval
        let reduceMotion: Bool
    }

    @Published private(set) var ripples: [Item] = []
    var reduceMotion = false
    var uninstallMonitor: (() -> Void)?

    func append(point: CGPoint) {
        let item = Item(
            id: UUID(),
            point: point,
            duration: reduceMotion ? QQMotion.rippleReducedDuration : QQMotion.rippleDuration,
            reduceMotion: reduceMotion
        )
        ripples = QQMotion.appendRipple(ripples, item)
        let id = item.id
        let duration = item.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.remove(id)
        }
    }

    func remove(_ id: UUID) {
        ripples.removeAll { $0.id == id }
    }

    func removeAll() {
        ripples.removeAll()
    }

    func shutdown() {
        uninstallMonitor?()
        removeAll()
    }
}

struct QQWindowRippleOverlay: View {
    var tint: Color
    @StateObject private var model = QQRippleModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tint: Color = QQTheme.indigo) {
        self.tint = tint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                QQRippleMonitorRepresentable(model: model)
                ForEach(model.ripples) { ripple in
                    QQClickRippleGlyph(
                        tint: tint,
                        duration: ripple.duration,
                        reduceMotion: ripple.reduceMotion
                    )
                    .position(ripple.point)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { model.reduceMotion = reduceMotion }
        .onDisappear { model.shutdown() }
        .onChange(of: reduceMotion) { _, reduce in
            model.reduceMotion = reduce
            model.removeAll()
        }
    }
}

private struct QQClickRippleGlyph: View {
    var tint: Color
    var duration: TimeInterval
    var reduceMotion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18 * (1 - Double(progress))))
                .frame(width: 34, height: 34)
                .scaleEffect(reduceMotion ? 1 : 0.35 + progress * 2.7)
            Circle()
                .strokeBorder(tint.opacity(0.42 * (1 - Double(progress))), lineWidth: 1.15)
                .frame(width: 26, height: 26)
                .scaleEffect(reduceMotion ? 1 : 0.45 + progress * 3.3)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: duration)) { progress = 1 }
        }
    }
}

private final class QQRippleHitView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { onWindow?(nil) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

private struct QQRippleMonitorRepresentable: NSViewRepresentable {
    var model: QQRippleModel

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(model: model)
        model.uninstallMonitor = { [weak coordinator] in coordinator?.uninstall() }
        return coordinator
    }

    func makeNSView(context: Context) -> QQRippleHitView {
        let view = QQRippleHitView()
        context.coordinator.hostView = view
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.bind(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: QQRippleHitView, context: Context) {
        context.coordinator.model = model
        context.coordinator.hostView = nsView
        // window 暂时为 nil 时不要拆监听；真正离开窗口由 viewWillMove / dismantle / willClose 处理。
        if let window = nsView.window {
            context.coordinator.bind(window: window)
        }
    }

    static func dismantleNSView(_ nsView: QQRippleHitView, coordinator: Coordinator) {
        nsView.onWindow = nil
        coordinator.hostView = nil
        coordinator.uninstall()
    }

    final class Coordinator {
        var model: QQRippleModel
        var monitor: Any?
        var closeObserver: NSObjectProtocol?
        weak var window: NSWindow?
        weak var hostView: QQRippleHitView?

        init(model: QQRippleModel) { self.model = model }

        func bind(window: NSWindow?) {
            guard let window else {
                uninstall()
                return
            }
            if self.window === window, monitor != nil { return }
            uninstall()
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.uninstall()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.record(event)
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            window = nil
        }

        func record(_ event: NSEvent) {
            guard let window, let host = hostView else { return }
            let height = host.bounds.height
            guard QQMotion.shouldRecordHostClick(
                hostInWindow: host.window === window,
                hostHeight: height,
                appIsActive: NSApp.isActive,
                eventWindowIsTarget: event.window === window,
                eventType: event.type
            ) else { return }
            guard let point = QQMotion.hostClickPoint(
                locationInWindow: event.locationInWindow,
                hostIsFlipped: host.isFlipped,
                hostHeight: height,
                convertToWindow: { host.convert($0, to: nil) }
            ) else { return }
            // 先把原事件交回去，再在下一轮记下涟漪，避免在监听回调里改 SwiftUI。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, let host = self.hostView, host.window === self.window else { return }
                self.model.append(point: point)
            }
        }

        deinit { uninstall() }
    }
}
