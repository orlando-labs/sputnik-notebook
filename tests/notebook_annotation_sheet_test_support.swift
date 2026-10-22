import AppKit
import SwiftUI

struct AnnotationSheetTestFailure: Error { let message: String }
@MainActor enum AnnotationSheetTestSupport {
    static func property(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }
    static func element(_ root: NSObject, id: String) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if property(object, "accessibilityIdentifier") as? String == id { return object }
            for child in property(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            if let view = object as? NSView { for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } } }
            return nil
        }
        return find(root, depth: 0)
    }
    static func click(_ id: String, window: NSWindow) throws {
        guard let root = window.contentView else { throw AnnotationSheetTestFailure(message: "Missing sheet content") }
        let point: CGPoint
        if let object = element(root, id: id), let frame = property(object, "accessibilityFrame") as? NSValue, frame.rectValue.width > 0 {
            point = window.convertPoint(fromScreen: CGPoint(x: frame.rectValue.midX, y: frame.rectValue.midY))
        } else {
            // SwiftUI's AX tree can be absent in a headless test host. These
            // Each fixed-size fixture has a known final action row. The audio
            // component's compact row sits lower than the image editor's row.
            let x = id == "annotation-schema-save" ? root.bounds.width - 70 : id.hasSuffix("discard") ? root.bounds.width - 124 : id.hasSuffix("apply") ? root.bounds.width - 55 : 92.0
            let bottom = id == "audio-annotate" ? 20.0 : 31.0
            let y = id == "board-annotation-classes" ? (root.isFlipped ? 31.0 : root.bounds.height - 31) : root.isFlipped ? root.bounds.height - bottom : bottom
            point = root.convert(CGPoint(x: x, y: y), to: nil)
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw AnnotationSheetTestFailure(message: "Cannot synthesize annotation button click") }
            window.sendEvent(event)
        }
    }
    static func edit(_ placeholder: String, text: String, window: NSWindow) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let root = window.contentView, let field = fields(root).first(where: { $0.placeholderString == placeholder && $0.isEditable }) else {
            throw AnnotationSheetTestFailure(message: "Missing editable coordinate field: " + placeholder)
        }
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw AnnotationSheetTestFailure(message: "Missing native field editor: " + placeholder) }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }
    static func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    static func editTranscript(_ text: String, window: NSWindow) throws {
        let views = window.contentView.map(textViews)?.filter(\.isEditable) ?? []
        guard views.count == 1, let view = views.first else { throw AnnotationSheetTestFailure(message: "Expected exactly one permitted transcript editor") }
        window.makeFirstResponder(view); view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText(text, replacementRange: view.selectedRange()); window.makeFirstResponder(nil)
    }
    static func designerConfiguration(_ initial: NotebookBoardComponent) async throws -> NotebookBoardComponent {
        var component = initial
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
        window.contentView = NSHostingView(rootView: NotebookAnnotationSettingsView(component: .init(get: { component }, set: { component = $0 })).padding(20).frame(width: 420, height: 420, alignment: .topLeading))
        try await Task.sleep(nanoseconds: 200_000_000)
        try click("board-annotation-classes", window: window)
        let deadline = Date().addingTimeInterval(5)
        while window.attachedSheet == nil && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        guard let sheet = window.attachedSheet, sheet.contentView!.bounds.width >= 780 else { throw AnnotationSheetTestFailure(message: "Designer class schema editor did not open") }
        try await Task.sleep(nanoseconds: 200_000_000)
        try edit("Class name", text: "Configured class", window: sheet)
        try edit("Attribute name", text: "Configured attribute", window: sheet)
        try await Task.sleep(nanoseconds: 50_000_000)
        try click("annotation-schema-save", window: sheet)
        let closing = Date().addingTimeInterval(5)
        while window.attachedSheet != nil && Date() < closing { try await Task.sleep(nanoseconds: 30_000_000) }
        guard component.annotation_classes?.first?.title == "Configured class", component.annotation_classes?.first?.attributes.first?.title == "Configured attribute" else { throw AnnotationSheetTestFailure(message: "Designer schema edits did not update the component draft") }
        return component
    }
    static func opens(window: NSWindow, button: String, editor: String, discard: String, output: URL? = nil) async throws {
        window.center(); window.orderFrontRegardless(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if let output, let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.deletingLastPathComponent().appendingPathComponent(button + "-source.png"))
        }
        try click(button, window: window)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let sheet = window.attachedSheet, let content = sheet.contentView,
               content.bounds.width >= 900, content.bounds.height >= 600 { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        guard let sheet = window.attachedSheet, let content = sheet.contentView,
              content.bounds.width >= 900, content.bounds.height >= 600 else {
            let frames = NSApp.windows.filter(\.isVisible).map { "\($0.frame) content=\($0.contentView?.bounds ?? .zero) attached=\($0.attachedSheet != nil)" }.joined(separator: "; ")
            throw AnnotationSheetTestFailure(message: "Annotate opened an empty/undersized sheet: " + editor + " · " + frames)
        }
        try await Task.sleep(nanoseconds: 650_000_000)
        if let output {
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        }
        try click(discard, window: sheet)
        let closed = Date().addingTimeInterval(5)
        while window.attachedSheet != nil && Date() < closed { try await Task.sleep(nanoseconds: 30_000_000) }
        if window.attachedSheet != nil { throw AnnotationSheetTestFailure(message: "Discard did not dismiss annotation sheet") }
    }
}
