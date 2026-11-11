// Manual Mac WebKit check on an insecure LAN origin. The Copy step uses a real native click.
import AppKit
import WebKit

@MainActor final class ChatWebKitCheck {
    let window: NSWindow
    let web: WKWebView
    init() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Chat WebKit QA"; window.contentView = web; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func evaluate(_ script: String) async throws -> Any { (try await web.evaluateJavaScript(script)) ?? NSNull() }
    func until(_ expression: String, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await evaluate(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "ChatWebKitQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + expression])
    }
    func run(sessionFile: String, output: String) async throws {
        let session = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sessionFile))) as! [String: Any]
        let url = URL(string: session["viewerURL"] as! String)!
        guard url.scheme == "http", let host = url.host, host != "localhost", !host.hasPrefix("127.") else {
            throw NSError(domain: "ChatWebKitQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use an actual insecure HTTP LAN origin, not localhost"])
        }
        let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        web.load(URLRequest(url: url))
        try await until("!!globalThis.SetbeamChat && !!document.getElementById('join-name')")
        _ = try await evaluate("document.getElementById('join-name').value='WebKit participant';document.getElementById('join-submit').click();true")
        try await until("document.getElementById('chat-toggle').hidden===false")
        _ = try await evaluate("document.getElementById('chat-toggle').click();true")
        try await until("document.querySelectorAll('.chat-message').length>=2")
        guard try await evaluate("window.isSecureContext===false && typeof navigator.clipboard==='undefined'") as? Bool == true else {
            throw NSError(domain: "ChatWebKitQA", code: 3, userInfo: [NSLocalizedDescriptionKey: "The LAN page unexpectedly has a secure clipboard API"])
        }
        _ = try await evaluate("document.getElementById('chat-log').focus();document.getElementById('chat-log').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));true")
        try await until("document.getElementById('chat-menu').hidden===false")
        guard try await evaluate("document.querySelectorAll('#chat-menu [role=menuitemradio]').length===6 && document.querySelectorAll('.chat-message[tabindex=\"0\"]').length===1") as? Bool == true else {
            throw NSError(domain: "ChatWebKitQA", code: 4, userInfo: [NSLocalizedDescriptionKey: "Menu roles or keyboard traversal failed"])
        }
        window.setContentSize(NSSize(width: 390, height: 640)); web.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        _ = try await evaluate("window.dispatchEvent(new Event('resize'));true")
        try await until("(()=>{const m=document.getElementById('chat-menu'),r=m.getBoundingClientRect();return !m.hidden&&r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight})()")
        _ = try await evaluate("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));true")
        guard try await evaluate("document.getElementById('chat-menu').hidden && !document.getElementById('chat-panel').hidden") as? Bool == true else {
            throw NSError(domain: "ChatWebKitQA", code: 5, userInfo: [NSLocalizedDescriptionKey: "Escape closed chat instead of only the menu"])
        }
        let expected = try await evaluate("document.querySelector('.chat-message .chat-text').textContent") as! String
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        } ?? []
        defer { if pasteboard.string(forType: .string) == expected { pasteboard.clearContents(); pasteboard.writeObjects(saved) } }
        _ = try await evaluate("document.querySelector('.chat-message').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));true")
        try await until("document.getElementById('chat-menu').hidden===false")
        try JSONSerialization.data(withJSONObject: ["readyForNativeCopyClick":true,"insecureLAN":true]).write(to: directory.appendingPathComponent("copy-ready.json"))
        print("READY: click Copy in the Chat WebKit QA window")
        try await until("document.getElementById('chat-status').textContent==='Copied'", seconds: 120)
        guard pasteboard.string(forType: .string) == expected else {
            throw NSError(domain: "ChatWebKitQA", code: 6, userInfo: [NSLocalizedDescriptionKey: "Copy did not place the exact message on the clipboard"])
        }
        let snapshot = try await web.takeSnapshot(configuration: nil)
        let image = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try image.write(to: directory.appendingPathComponent("webkit-lan-copy.png"))
        let result: [String: Any] = ["passed":true,"engine":"macOS WKWebView","secureContext":false,"clipboardAPIAvailable":false,"nativeClickCopy":true,"exactClipboardText":true,"rovingKeyboard":true,"menuRoles":true,"resizePreservesMenu":true,"escapePreservesChat":true,"physicalIOS":false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("webkit-chat-results.json"))
        print("PASS: insecure LAN WebKit Copy, menu roles, keyboard, resizing and Escape")
        window.close()
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
Task { @MainActor in
    do {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "ChatWebKitQA", code: 0) }
        try await ChatWebKitCheck().run(sessionFile: CommandLine.arguments[1], output: CommandLine.arguments[2]); exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
app.run()
