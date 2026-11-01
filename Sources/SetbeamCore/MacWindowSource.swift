import AppKit
import ScreenCaptureKit
import Darwin

/// One application window during its owner's lifetime. The title is a label only and never
/// selects a window: the window number, owner process ID, and that process's start time must all match.
public struct MacWindowIdentity: Codable, Hashable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    /// Microseconds since 1970. A reused process ID has a different start time.
    public let processStart: Int64
    public init(windowID: UInt32, processID: Int32, processStart: Int64) {
        self.windowID = windowID; self.processID = processID; self.processStart = processStart
    }
    public var isComplete: Bool { windowID != 0 && processID > 0 && processStart > 0 }
}

public enum MacProcess {
    /// Kernel start time of a running process, or nil when it no longer exists.
    public static func startTime(_ pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }
}

/// Minimized windows, hidden applications, and some closed but retained AppKit windows
/// all report the same off-screen metadata, so they share `hidden`. Only a missing window
/// number or owner process is `closed`.
public enum MacWindowPresence: String, Equatable, Sendable { case visible, hidden, closed }

public struct MacWindowRow: Equatable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    public let onScreen: Bool
    public let title: String?
    public init(windowID: UInt32, processID: Int32, onScreen: Bool, title: String? = nil) {
        self.windowID = windowID; self.processID = processID; self.onScreen = onScreen; self.title = title
    }
}

public enum MacWindowLocator {
    public static func presence(of identity: MacWindowIdentity, rows: [MacWindowRow]?, processStart: (Int32) -> Int64?) -> MacWindowPresence {
        guard identity.isComplete, processStart(identity.processID) == identity.processStart else { return .closed }
        // An unreadable window list is not evidence of closure; wait without capturing.
        guard let rows else { return .hidden }
        guard let row = rows.first(where: { $0.windowID == identity.windowID }), row.processID == identity.processID else { return .closed }
        return row.onScreen ? .visible : .hidden
    }
    /// The current presence and, with Screen Recording access, the window's current title.
    public static func status(of identity: MacWindowIdentity) -> (presence: MacWindowPresence, title: String?) {
        let rows = self.rows()
        let presence = presence(of: identity, rows: rows, processStart: MacProcess.startTime)
        let title = presence == .closed ? nil : rows?.first { $0.windowID == identity.windowID }?.title
        return (presence, title)
    }
    /// Throws unless the exact window is on screen. Never chooses another window.
    public static func require(_ identity: MacWindowIdentity) throws {
        switch status(of: identity).presence {
        case .visible: return
        case .hidden: throw SetbeamError.unavailable(hiddenMessage)
        case .closed: throw SetbeamError.unavailable(closedMessage)
        }
    }
    public static let hiddenMessage = "Show the selected window. Setbeam waits for that same window."
    public static let closedMessage = "The selected window closed. Choose a window again; Setbeam never substitutes another one."

    /// Every window, including minimized ones. A targeted lookup omits minimized windows.
    static func rows() -> [MacWindowRow]? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { row in
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            return MacWindowRow(windowID: id, processID: pid, onScreen: (row[kCGWindowIsOnscreen as String] as? Bool) == true,
                                title: row[kCGWindowName as String] as? String)
        }
    }
}

/// A chooser entry for one shareable application window.
public struct MacWindow: Identifiable, Equatable, Sendable {
    public let identity: MacWindowIdentity
    public let applicationName: String
    public let bundleIdentifier: String?
    public let title: String
    public let width: Int
    public let height: Int
    public var id: MacWindowIdentity { identity }
    /// Window capture has no display mode; this ceiling is capped to 30 fps like every Setbeam encode.
    public static let nativeFrameRate = 60

    public init(identity: MacWindowIdentity, applicationName: String, bundleIdentifier: String?, title: String, width: Int, height: Int) {
        self.identity = identity; self.bundleIdentifier = bundleIdentifier; self.width = width; self.height = height
        self.applicationName = Self.clean(applicationName).isEmpty ? "Application" : Self.clean(applicationName)
        self.title = Self.clean(title)
    }
    public var label: String { Self.label(title) }
    public var sourceName: String { Self.sourceName(application: applicationName, title: title) }
    public static func label(_ title: String) -> String { clean(title).isEmpty ? "Untitled window" : clean(title) }
    public static func sourceName(application: String, title: String) -> String { "\(application) · \(label(title))" }

    /// Single-line, bounded text for labels. Window titles can contain anything.
    public static func clean(_ text: String) -> String {
        let flat = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }
    /// Ordinary application windows of other processes, large enough to be useful.
    public static func isEligible(processID: Int32?, ownProcessID: Int32, layer: Int, onScreen: Bool, frame: CGRect) -> Bool {
        guard let processID, processID > 0, processID != ownProcessID, layer == 0, onScreen else { return false }
        return [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width >= 64 && frame.height >= 48
    }
    /// Application, then title, then window number, so the chooser order is stable between refreshes.
    public static func precedes(_ a: MacWindow, _ b: MacWindow) -> Bool {
        if a.applicationName != b.applicationName { return a.applicationName.localizedStandardCompare(b.applicationName) == .orderedAscending }
        if a.label != b.label { return a.label.localizedStandardCompare(b.label) == .orderedAscending }
        return a.identity.windowID < b.identity.windowID
    }
    /// Shareable windows with their ScreenCaptureKit handles. Requires Screen Recording access;
    /// callers check it first so listing never prompts.
    @MainActor public static func shareable() async throws -> [(window: MacWindow, handle: SCWindow)] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = ProcessInfo.processInfo.processIdentifier
        var starts: [Int32: Int64] = [:]
        let found: [(window: MacWindow, handle: SCWindow)] = content.windows.compactMap { handle in
            let pid = handle.owningApplication?.processID
            guard isEligible(processID: pid, ownProcessID: own, layer: handle.windowLayer, onScreen: handle.isOnScreen, frame: handle.frame),
                  let pid, let application = handle.owningApplication else { return nil }
            if starts[pid] == nil { starts[pid] = MacProcess.startTime(pid) }
            guard let start = starts[pid] else { return nil }
            let scale = pixelScale(at: handle.frame)
            let window = MacWindow(identity: MacWindowIdentity(windowID: handle.windowID, processID: pid, processStart: start),
                applicationName: application.applicationName, bundleIdentifier: application.bundleIdentifier.isEmpty ? nil : application.bundleIdentifier,
                title: handle.title ?? "", width: Int((handle.frame.width * scale).rounded()), height: Int((handle.frame.height * scale).rounded()))
            return (window, handle)
        }
        return found.sorted { precedes($0.window, $1.window) }
    }
    /// Backing pixels per point for the display under a window's centre.
    static func pixelScale(at frame: CGRect) -> CGFloat {
        var display = CGDirectDisplayID(), count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count) == .success, count == 1,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}
