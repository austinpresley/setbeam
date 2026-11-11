import XCTest
import AppKit
import SwiftUI
@testable import SetbeamCore
@testable import SetbeamApp

final class JoinRequestTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 20_000)

    private func viewer(_ number: Int, _ name: String, admission: ViewerAdmission = .pending, shortAddress: Bool = false, joined: Date? = nil) -> ViewerActivity {
        var value = ViewerActivity(id: "viewer-\(number)", label: "Phone / tablet browser", playing: false, onThisMac: false, revision: -1,
                                   lastSeen: start, number: number, name: name, health: .connecting)
        value.admission = admission; value.shortAddress = shortAddress; value.joinedAt = joined ?? start.addingTimeInterval(Double(number))
        return value
    }

    func testEachRequestIsAnnouncedOnceAcrossHeartbeatsReloadsAndLinks() {
        var tracker = JoinRequestTracker()
        XCTAssertEqual(tracker.observe(link: 1, active: true, viewers: [viewer(2, "Sam")]).map(\.name), ["Sam"])
        // Heartbeats and a reloaded waiting tab keep the same session number.
        XCTAssertTrue(tracker.observe(link: 1, active: true, viewers: [viewer(2, "Sam")]).isEmpty)
        XCTAssertTrue(tracker.observe(link: 1, active: true, viewers: []).isEmpty, "A row that briefly drops out is not a new request")
        XCTAssertTrue(tracker.observe(link: 1, active: true, viewers: [viewer(2, "Sam")]).isEmpty)
        let both = tracker.observe(link: 1, active: true, viewers: [viewer(5, "Kai", shortAddress: true), viewer(2, "Sam"), viewer(3, "Lee", admission: .admitted)])
        XCTAssertEqual(both.map(\.name), ["Kai"])
        XCTAssertEqual(tracker.pending.map(\.number), [2, 5], "Oldest first, waiting requests only")
        XCTAssertEqual(tracker.pending.last?.shortAddress, true)
        // Approval off or Stop: nothing waits and nothing is announced.
        XCTAssertTrue(tracker.observe(link: 1, active: false, viewers: [viewer(6, "Ana")]).isEmpty)
        XCTAssertTrue(tracker.pending.isEmpty)
        // A new link numbers from 1 again, so its first request is new even with a familiar number.
        XCTAssertEqual(tracker.observe(link: 2, active: true, viewers: [viewer(2, "Sam")]).count, 1)
    }

    func testACardActsOnlyOnTheSameWaitingRequest() {
        let request = JoinRequest(viewer(4, "Sam"), link: 7)
        XCTAssertEqual(request.current(in: [viewer(4, "Sam")], link: 7)?.number, 4)
        XCTAssertNil(request.current(in: [viewer(4, "Sam")], link: 8), "A card from an earlier link")
        XCTAssertNil(request.current(in: [viewer(4, "Sam", admission: .admitted)], link: 7), "Already admitted in the main window")
        XCTAssertNil(request.current(in: [viewer(4, "Sam", admission: .declined)], link: 7))
        XCTAssertNil(request.current(in: [], link: 7), "Lapsed")
        XCTAssertNil(request.current(in: [viewer(4, "Ana", joined: start.addingTimeInterval(99))], link: 7), "Another request with the same number")
    }

    @MainActor func testTheCenterMirrorsWaitingRequestsAndClearsAtStop() {
        let center = JoinRequestCenter()
        center.observe(link: 1, active: true, viewers: [viewer(1, "Sam"), viewer(2, "Kai")])
        center.observe(link: 1, active: true, viewers: [viewer(1, "Sam"), viewer(2, "Kai")])
        XCTAssertEqual(center.requests.map(\.name), ["Sam", "Kai"]); XCTAssertEqual(center.alerts, 2)
        center.observe(link: 1, active: true, viewers: [viewer(2, "Kai")])
        XCTAssertEqual(center.requests.map(\.name), ["Kai"], "Answered elsewhere, the card drops the row")
        center.observe(link: 1, active: false, viewers: [viewer(2, "Kai")])
        XCTAssertTrue(center.requests.isEmpty); XCTAssertFalse(center.isShowing); XCTAssertEqual(center.alerts, 2)
    }

    @MainActor func testStaleAnswersDoNothingWithoutSharingOrApproval() {
        let model = SessionModel(preferences: preferences())
        XCTAssertFalse(model.answer(JoinRequest(viewer(1, "Sam"), link: model.viewingLink), admit: true))
    }

    @MainActor func testShortAddressIsOptInAndExplainsWhatItNeeds() throws {
        let defaults = preferences()
        let model = SessionModel(preferences: defaults)
        XCTAssertFalse(model.shortAddressEnabled, "Off by default")
        XCTAssertFalse(model.shortAddressOpen)
        XCTAssertEqual(model.shortAddressStatus.text, "Off. Viewers need the whole link or QR code.")
        model.setShortAddress(enabled: true)
        XCTAssertTrue(SessionModel(preferences: defaults).shortAddressEnabled, "Saved")
        XCTAssertEqual(model.shortAddressStatus.text, "Turn on Ask before viewers join. Until then, typing setbeam.local doesn't open anything.")
        XCTAssertTrue(model.shortAddressStatus.attention)
        model.setViewerApproval(true)
        XCTAssertFalse(model.shortAddressOpen, "Never open without sharing")
        XCTAssertEqual(model.shortAddressStatus.text, model.canInviteOtherDevices
            ? "Viewers can type setbeam.local and ask to join while you share." : "Choose a viewing network to use setbeam.local.")
        model.setLocalAddress(enabled: false, label: "setbeam")
        XCTAssertEqual(model.shortAddressStatus.text, "Turn on Offer a local address to use this.")
        XCTAssertNil(model.shortAddressHost)

        // While sharing, the listener's problems name the fallback.
        var state = SessionState()
        state.beginMonitoring(); state.updateSource(available: true)
        try state.startSharing(); state.updateAudience(available: true)
        let sharing = SessionModel(initialState: state, preferences: defaults)
        sharing.setLocalAddress(enabled: true, label: "stage-a")
        sharing.shortAddressChanged(.unavailable(.inUse))
        XCTAssertFalse(sharing.shortAddressOpen, "No viewing link yet, so nothing answers")
        XCTAssertNil(sharing.shortAddressHost)
    }

    private func preferences() -> UserDefaults {
        let suite = "app.setbeam.tests.join-requests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}

/// Review round 1: fixed white on the accent measured 3.23:1 on the dark card.
final class CardButtonPaletteTests: XCTestCase {
    private typealias RGB = CardButtonPalette.RGB

    private func resolved(_ color: NSColor, dark: Bool) -> RGB {
        var value = RGB(0, 0, 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let srgb = color.usingColorSpace(.sRGB)!
            value = RGB(srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        }
        return value
    }

    /// Every phase reaches the target, hover and press never lower contrast, and on real accents they change the fill.
    /// (Hover and press also add a stroke, so pure black or white still respond.)
    private func assertReadable(_ palette: CardButtonPalette, _ what: String, distinct: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let rest = palette.contrast(.rest)
        XCTAssertGreaterThanOrEqual(rest, CardButtonPalette.target, what, file: file, line: line)
        for phase in [CardButtonPalette.Phase.hover, .pressed] {
            XCTAssertGreaterThanOrEqual(palette.contrast(phase), rest, "\(what): \(phase) must not lower contrast", file: file, line: line)
            if distinct { XCTAssertNotEqual(palette.fill(phase), palette.restFill, "\(what): \(phase) must look different", file: file, line: line) }
        }
    }

    func testAdmitIsReadableOnEveryAccentInBothModes() {
        let accents: [(String, NSColor)] = [("blue", .systemBlue), ("purple", .systemPurple), ("pink", .systemPink), ("red", .systemRed),
                                            ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen),
                                            ("graphite", .systemGray), ("current", .controlAccentColor)]
        for dark in [false, true] {
            for (name, color) in accents { assertReadable(.prominent(accent: resolved(color, dark: dark)), "\(name), dark \(dark)") }
            // What SwiftUI draws for the accent color is what the card resolves.
            var environment = EnvironmentValues(); environment.colorScheme = dark ? .dark : .light
            let swiftUI = RGB(Color.accentColor.resolve(in: environment))
            assertReadable(.prominent(accent: swiftUI), "SwiftUI accent, dark \(dark)")
            assertReadable(.secondary(dark: dark), "Decline, dark \(dark)")
        }
        // The round 1 pair, fixed white on the dark-mode accent, was below the floor.
        let blue = resolved(.systemBlue, dark: true)
        XCTAssertLessThan(CardButtonPalette.contrast(.white, blue), 4.5)
        // Blue, purple, pink, and red keep white text; yellow, orange, and green take dark text.
        for dark in [false, true] {
            for color in [NSColor.systemBlue, .systemPurple, .systemPink, .systemRed] {
                XCTAssertEqual(CardButtonPalette.prominent(accent: resolved(color, dark: dark)).text, .white)
            }
            for color in [NSColor.systemYellow, .systemOrange, .systemGreen] {
                XCTAssertEqual(CardButtonPalette.prominent(accent: resolved(color, dark: dark)).text, .ink)
            }
        }
    }

    func testAnyAccentColorReachesTheTarget() {
        let steps = stride(from: 0.0, through: 1, by: 0.125)
        for red in steps { for green in steps { for blue in steps {
            assertReadable(.prominent(accent: RGB(red, green, blue)), "accent \(red) \(green) \(blue)", distinct: false)
        } } }
    }
}

