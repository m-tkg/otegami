import Cocoa
import ApplicationServices

func windowsFor(pid: pid_t) {
    let appRef = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
    guard result == .success, let windows = value as? [AXUIElement] else {
        print("no windows (AX error \(result.rawValue))")
        return
    }
    for w in windows {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeValue)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posValue { AXValueGetValue(posValue as! AXValue, .cgPoint, &pos) }
        if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleValue)
        let title = (titleValue as? String) ?? "?"
        print("window '\(title)' pos=\(pos) size=\(size)")
    }
}

func click(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
}

func rightClick(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
    let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
}

func typeText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for scalar in text.unicodeScalars {
        var chars: [UniChar] = [UniChar(scalar.value)]
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down?.post(tap: .cghidEventTap)
        usleep(15_000)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up?.post(tap: .cghidEventTap)
        usleep(15_000)
    }
}

func keyPress(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    down?.postToPid(pid)
    usleep(30_000)
    up?.postToPid(pid)
}

func activate(pid: pid_t) {
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [.activateAllWindows])
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: driver <windows|click|rightclick|key|type|activate> ...")
    exit(1)
}

switch args[1] {
case "windows":
    guard args.count >= 3, let pid = pid_t(args[2]) else { print("need pid"); exit(1) }
    windowsFor(pid: pid)
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { print("need x y"); exit(1) }
    click(x: x, y: y)
case "rightclick":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { print("need x y"); exit(1) }
    rightClick(x: x, y: y)
case "key":
    guard args.count >= 4, let pid = pid_t(args[2]), let code = UInt16(args[3]) else { print("need pid keycode"); exit(1) }
    var flags: CGEventFlags = []
    if args.count >= 5 {
        if args[4].contains("cmd") { flags.insert(.maskCommand) }
        if args[4].contains("shift") { flags.insert(.maskShift) }
    }
    keyPress(pid: pid, keyCode: CGKeyCode(code), flags: flags)
case "type":
    guard args.count >= 3 else { print("need text"); exit(1) }
    typeText(args[2...].joined(separator: " "))
case "activate":
    guard args.count >= 3, let pid = pid_t(args[2]) else { print("need pid"); exit(1) }
    activate(pid: pid)
default:
    print("unknown command \(args[1])")
}
