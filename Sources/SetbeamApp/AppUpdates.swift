import AppKit
import Combine
import Sparkle

/// Whether this launch may contact the public update feed.
///
/// Only release builds carry `SUFeedURL`. Integration and QA launches always pass
/// arguments and must stay offline; Finder, the Dock and Sparkle's relaunch pass none.
enum UpdateAvailability: Equatable {
    case enabled
    case noFeed
    case testLaunch

    static func resolve(feedURL: String?, arguments: [String], environment: [String: String]) -> Self {
        // Plain HTTP is accepted only from this Mac, for local update QA. Releases use HTTPS.
        guard let url = feedURL.flatMap(URL.init(string:)),
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host))
        else { return .noFeed }
        if arguments.count > 1 || environment["SETBEAM_DISABLE_UPDATES"] == "1" { return .testLaunch }
        return .enabled
    }

    var explanation: String {
        switch self {
        case .enabled: "Setbeam checks GitHub for signed updates. Installing one quits and reopens the app."
        case .noFeed: "This developer build doesn't check for updates. Download a release to get updates."
        case .testLaunch: "Updates are off for this test launch."
        }
    }
}

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    /// A scheduled update found while sharing, shown in menus until the operator opens it.
    @Published private(set) var waitingVersion: String?
    let availability: UpdateAvailability
    var isSharing: () -> Bool = { false }
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()

    init(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        availability = .resolve(feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                arguments: arguments, environment: environment)
        super.init()
        guard availability == .enabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] in self?.lastChecked = $0 }.store(in: &observations)
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    /// Also brings a waiting scheduled update into focus.
    func checkForUpdates() {
        guard let controller, canCheck || waitingVersion != nil else { return }
        waitingVersion = nil
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }

    // MARK: Sparkle delegates

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update never interrupts an active share; it waits in the menus instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !isSharing() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { waitingVersion = handleShowingUpdate ? nil : version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waitingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waitingVersion = nil }
    }
}
