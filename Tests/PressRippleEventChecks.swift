import AppKit

// 真实 NSEvent 走生产 qqButtonRippleEvent。不打开窗口，不发送事件，不读源码文本。
@main
enum PressRippleEventChecks {
    static func main() {
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("PASS \(name)")
            } else {
                failed += 1
                print("FAIL \(name)")
            }
            fflush(stdout)
        }

        check("nil event has no keyboard fields", {
            let fields = qqButtonRippleEvent(nil)
            return fields.type == nil && fields.keyCode == nil && fields.characters == nil
        }())

        let mouseTypes: [(String, NSEvent.EventType)] = [
            ("left down", .leftMouseDown),
            ("left up", .leftMouseUp),
            ("right down", .rightMouseDown),
            ("right up", .rightMouseUp),
            ("other down", .otherMouseDown),
            ("other up", .otherMouseUp),
        ]
        for (name, type) in mouseTypes {
            guard let event = mouse(type) else {
                check("\(name) NSEvent exists", false)
                continue
            }
            check("\(name) real mouse event", event.type == type)
            let fields = qqButtonRippleEvent(event)
            check("\(name) extraction uses the event type", fields.type == event.type)
            check("\(name) extraction does not read keyCode", fields.keyCode == nil && fields.characters == nil)
            check("\(name) does not draw button ripple", draws(fields) == false)
        }

        if let scroll = scrollWheel() {
            check("scroll is a scroll wheel event", scroll.type == .scrollWheel)
            let fields = qqButtonRippleEvent(scroll)
            check("scroll extraction uses the event type", fields.type == scroll.type)
            check("scroll extraction does not read keyCode", fields.keyCode == nil && fields.characters == nil)
            check("scroll does not draw button ripple", draws(fields) == false)
        } else {
            check("scroll NSEvent exists", false)
        }

        if let flags = flagsChanged() {
            check("flagsChanged is not a keyDown", flags.type == .flagsChanged)
            let fields = qqButtonRippleEvent(flags)
            check("flagsChanged extraction uses the event type", fields.type == flags.type)
            check("flagsChanged extraction does not read keyCode", fields.keyCode == nil && fields.characters == nil)
            check("flagsChanged does not draw button ripple", draws(fields) == false)
        } else {
            check("flagsChanged NSEvent exists", false)
        }

        if let defined = applicationDefined() {
            check("applicationDefined event", defined.type == .applicationDefined)
            let fields = qqButtonRippleEvent(defined)
            check("applicationDefined extraction uses the event type", fields.type == defined.type)
            check("applicationDefined extraction does not read keyCode", fields.keyCode == nil && fields.characters == nil)
            check("applicationDefined does not draw button ripple", draws(fields) == false)
        } else {
            check("applicationDefined NSEvent exists", false)
        }

        if let space = key(.keyDown, characters: " ", keyCode: 49) {
            let fields = qqButtonRippleEvent(space)
            check("space keyDown type comes from the event", fields.type == space.type && fields.type == .keyDown)
            check("space keyDown reads keyCode and character", fields.keyCode == 49 && fields.characters == " ")
            check("space keyDown draws button ripple", draws(fields))
        } else {
            check("space keyDown NSEvent exists", false)
        }

        if let ret = key(.keyDown, characters: "\r", keyCode: 36) {
            let fields = qqButtonRippleEvent(ret)
            check("return keyDown type comes from the event", fields.type == ret.type)
            check("return keyDown reads keyCode and character", fields.keyCode == 36 && fields.characters == "\r")
            check("return keyDown draws button ripple", draws(fields))
        } else {
            check("return keyDown NSEvent exists", false)
        }

        if let enter = key(.keyUp, characters: "\u{3}", keyCode: 76) {
            let fields = qqButtonRippleEvent(enter)
            check("keypad enter keyUp type comes from the event", fields.type == enter.type && fields.type == .keyUp)
            check("keypad enter keyUp reads keyCode", fields.keyCode == 76)
            check("keypad enter keyUp draws button ripple", draws(fields))
        } else {
            check("keypad enter keyUp NSEvent exists", false)
        }

        if let letter = key(.keyDown, characters: "a", keyCode: 0) {
            let fields = qqButtonRippleEvent(letter)
            check("letter keyDown reads its own fields", fields.type == letter.type && fields.keyCode == 0 && fields.characters == "a")
            check("letter keyDown does not draw button ripple", draws(fields) == false)
        } else {
            check("letter keyDown NSEvent exists", false)
        }

        if let fallback = key(.keyUp, characters: " ", keyCode: 40) {
            let fields = qqButtonRippleEvent(fallback)
            check("space character fallback reads both fields", fields.keyCode == 40 && fields.characters == " ")
            check("space character fallback draws button ripple", draws(fields))
        } else {
            check("space character fallback NSEvent exists", false)
        }

        if failed == 0 {
            print("OK \(CommandLine.arguments[0])")
        } else {
            print("FAILED \(failed)")
        }
        exit(failed == 0 ? 0 : 1)
    }

    static func draws(_ fields: QQButtonRippleEvent) -> Bool {
        QQMotion.shouldDrawButtonRipple(
            isEnabled: true,
            reduceMotion: false,
            eventType: fields.type,
            keyCode: fields.keyCode,
            characters: fields.characters
        )
    }

    static func mouse(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 18, y: 36),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 7,
            clickCount: 1,
            pressure: type == .scrollWheel ? 0 : 1
        )
    }

    static func key(_ type: NSEvent.EventType, characters: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    static func scrollWheel() -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 2,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    static func flagsChanged() -> NSEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else { return nil }
        cg.type = .flagsChanged
        cg.flags = .maskShift
        return NSEvent(cgEvent: cg)
    }

    static func applicationDefined() -> NSEvent? {
        NSEvent.otherEvent(
            with: .applicationDefined,
            location: NSPoint(x: 4, y: 8),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            subtype: 1,
            data1: 2,
            data2: 3
        )
    }
}
