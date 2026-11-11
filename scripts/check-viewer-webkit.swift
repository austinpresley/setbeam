// Local WebKit engine QA. Pass an isolated --integration-demo session file and output folder.
import AppKit
import WebKit

@MainActor final class WebKitCheck {
    let window: NSWindow
    let web: WKWebView
    init() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFrontRegardless()
    }
    func evaluate(_ script: String) async throws -> Any { (try await web.evaluateJavaScript(script)) ?? NSNull() }
    func until(_ expression: String, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await evaluate(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "WebKitQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit condition timed out: " + expression])
    }
    func run(sessionFile: String, output: String) async throws {
        let session = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sessionFile))) as! [String: Any]
        let url = URL(string: session["viewerURL"] as! String)!
        web.load(URLRequest(url: url))
        try await until("!!globalThis.SetbeamChat && !!document.getElementById('join-name')")
        _ = try await evaluate("document.getElementById('join-name').value='WebKit viewer'; document.getElementById('join-colors').querySelector('input[value=purple]').click(); document.getElementById('join-submit').click(); true")
        try await until("document.getElementById('chat-toggle').hidden === false")
        try await until("document.getElementById('video').currentTime > 0.5", seconds: 30)
        _ = try await evaluate("document.getElementById('chat-toggle').click(); document.getElementById('chat-input').value='WebKit draft survives rotation'; document.getElementById('chat-input').dispatchEvent(new Event('input',{bubbles:true})); true")
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for (name, width, height) in [("webkit-iphone-portrait",390,844),("webkit-iphone-landscape",844,390),("webkit-ipad-mini-portrait",768,1024),("webkit-ipad-mini-landscape",1024,768),("webkit-ipad-portrait",820,1180),("webkit-ipad-landscape",1180,820),("webkit-short-keyboard",844,260)] {
            window.setContentSize(NSSize(width: width, height: height)); web.frame = NSRect(x: 0, y: 0, width: width, height: height)
            _ = try await evaluate("window.dispatchEvent(new Event('resize')); true")
            try await Task.sleep(nanoseconds: 150_000_000)
            let report = try await evaluate("(()=>{const r=document.getElementById('chat-send').getBoundingClientRect();return {width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,font:parseFloat(getComputedStyle(document.getElementById('chat-input')).fontSize),sendBottom:r.bottom,draft:document.getElementById('chat-input').value}})()") as! [String: Any]
            guard (report["scrollWidth"] as! Int) <= width + 1, (report["font"] as! Double) >= 16,
                  report["draft"] as? String == "WebKit draft survives rotation",
                  !(width > height && height < 550) || (report["sendBottom"] as! Double) <= Double(height + 1) else {
                throw NSError(domain: "WebKitQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebKit layout failed: \(name) \(report)"])
            }
            let image = try await web.takeSnapshot(configuration: nil)
            let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            reports.append(["name": name, "geometry": report])
        }
        _ = try await evaluate("document.getElementById('chat-capture').click(); true")
        try await until("document.getElementById('chat-preview').hidden === false")
        let result: [String: Any] = ["passed": true, "engine": "macOS WKWebView", "actualDecodedSample": true, "canvasCapture": true, "physicalIOS": false, "reports": reports]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("webkit-results.json"))
        print("PASS WebKit: decoded sample, canvas attachment, seven layouts and rotation draft. iOS keyboard/device tests remain separate.")
        window.close()
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "WebKitQA", code: 0, userInfo: [NSLocalizedDescriptionKey: "Usage: check-viewer-webkit session.json output-folder"]) }
        try await WebKitCheck().run(sessionFile: CommandLine.arguments[1], output: CommandLine.arguments[2]); exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
app.run()
