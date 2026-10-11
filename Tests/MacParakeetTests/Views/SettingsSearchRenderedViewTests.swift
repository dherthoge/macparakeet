import AppKit
import Sparkle
import SwiftUI
import Vision
import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

/// Rendered-view checks for Settings search.
///
/// `SettingsSearchIndexTests` covers the index as data. These mount the real
/// `SettingsView` in an offscreen window, type into the real search field,
/// draw the view into a bitmap, and read the text back out of the pixels, so a
/// row that is indexed but never reaches the results list still fails.
///
/// The text is read with Vision because SwiftUI draws `Text` without backing
/// `NSView`s and only builds its accessibility tree for an assistive client,
/// so neither is readable from inside the test process.
///
/// Set `MACPARAKEET_SETTINGS_SEARCH_SNAPSHOT_DIR` to also write one PNG per
/// query into that directory.
@MainActor
final class SettingsSearchRenderedViewTests: XCTestCase {
    private static let snapshotDirEnvironmentKey = "MACPARAKEET_SETTINGS_SEARCH_SNAPSHOT_DIR"
    private let noMatchesTitle = "No matches"

    private struct MountedSettings {
        let window: NSWindow
        let host: NSHostingView<SettingsView>
        let searchField: NSTextField
    }

    private func mountSettings(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MountedSettings {
        let suiteName = makeIsolatedDefaultsSuite("com.macparakeet.tests.settings-search-rendered.")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        // Never started, so it schedules no update checks.
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil),
            delegate: nil
        )
        let view = SettingsView(
            viewModel: SettingsViewModel(
                defaults: defaults,
                inputDevicesProvider: { [] },
                defaultInputDeviceUIDProvider: { nil }
            ),
            llmSettingsViewModel: LLMSettingsViewModel(defaults: defaults),
            voiceProfilesViewModel: VoiceProfilesViewModel(),
            updater: updater,
            onHotkeyRecordingStateChanged: { _ in }
        )

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Pinned so the secondary-text contrast does not follow the machine.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        settle()

        let searchField = try XCTUnwrap(
            findSearchField(in: host),
            "no NSTextField behind the Settings search field",
            file: file,
            line: line
        )
        // Control read: the tab bar is always drawn. If its text cannot be
        // read back, this environment cannot draw or recognize the view (no
        // window server), and a missing row below would prove nothing.
        let controlText = try recognizedText(in: try renderBitmap(of: host))
        try XCTSkipUnless(
            controlText.contains { $0.localizedCaseInsensitiveContains("Engine") },
            "offscreen Settings render has no readable text here: \(controlText)"
        )
        return MountedSettings(window: window, host: host, searchField: searchField)
    }

    private func settle(for seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findSearchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search settings" {
            return field
        }
        for subview in view.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }

    /// Replaces the search text through the field editor, so the query
    /// reaches the view through the field's own binding, as typed text does.
    private func type(
        _ query: String,
        into mounted: MountedSettings,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(mounted.window.makeFirstResponder(mounted.searchField), file: file, line: line)
        let editor = try XCTUnwrap(
            mounted.searchField.currentEditor() as? NSTextView,
            "search field has no field editor",
            file: file,
            line: line
        )
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
    }

    /// Draws the mounted view into a 2x bitmap regardless of the display the
    /// offscreen window landed on, so the text is large enough to read back.
    private func renderBitmap(of host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * 2),
                pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    /// One string per line of text Vision finds in the bitmap. A machine that
    /// cannot run text recognition (a CI VM without the Vision models or an
    /// inference context) skips the test instead of failing it.
    private func recognizedText(in bitmap: NSBitmapImageRep) throws -> [String] {
        guard let image = bitmap.cgImage else {
            throw XCTSkip("the offscreen Settings render produced no image here")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw XCTSkip("Vision text recognition is unavailable here: \(error)")
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Re-reads the drawn view until `isSettled` holds or the timeout passes.
    /// The timeout is only spent on a failing run.
    private func drawnText(
        in mounted: MountedSettings,
        until isSettled: ([String]) -> Bool
    ) throws -> (bitmap: NSBitmapImageRep, text: [String]) {
        let deadline = Date().addingTimeInterval(15)
        var bitmap: NSBitmapImageRep
        var text: [String]
        repeat {
            settle(for: 0.2)
            bitmap = try renderBitmap(of: mounted.host)
            text = try recognizedText(in: bitmap)
        } while !isSettled(text) && Date() < deadline
        return (bitmap, text)
    }

    /// Types `query` and returns the text drawn once `isSettled` holds. The
    /// search body crossfades in, so the first frames after typing can still
    /// show the previous state. A previous query is cleared first, and the
    /// results list must be gone before the next one is typed, so a frame left
    /// over from that query cannot satisfy this one.
    private func renderedText(
        afterTyping query: String,
        into mounted: MountedSettings,
        until isSettled: ([String]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        if !mounted.searchField.stringValue.isEmpty {
            try type("", into: mounted, file: file, line: line)
            let cleared = try drawnText(in: mounted) { text in
                !self.showsAnyResultCount(in: text) && !self.showsNoMatches(in: text)
            }
            XCTAssertFalse(
                showsAnyResultCount(in: cleared.text),
                "clearing the search field left the results list drawn: \(cleared.text)",
                file: file,
                line: line
            )
        }
        try type(query, into: mounted, file: file, line: line)
        let drawn = try drawnText(in: mounted, until: isSettled)
        XCTAssertEqual(mounted.searchField.stringValue, query, file: file, line: line)
        try writeSnapshotIfRequested(drawn.bitmap, query: query)
        return drawn.text
    }

    private func writeSnapshotIfRequested(_ bitmap: NSBitmapImageRep, query: String) throws {
        guard let rawDir = ProcessInfo.processInfo.environment[Self.snapshotDirEnvironmentKey],
            !rawDir.isEmpty
        else { return }
        let directory = URL(fileURLWithPath: rawDir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let name = "settings-search-" + query.replacingOccurrences(of: " ", with: "-") + ".png"
        try png.write(to: directory.appendingPathComponent(name))
    }

    /// Exact, case-sensitive line match: the typed query is drawn too, in the
    /// search field, and "push to talk" must not count as the "Push to talk" row.
    private func showsRow(_ title: String, in text: [String]) -> Bool {
        text.contains(title)
    }

    /// The "N results" caption is drawn only by the search results list, so it
    /// separates a result row from a settings row with the same title on a tab.
    private func showsAnyResultCount(in text: [String]) -> Bool {
        text.contains { $0.range(of: #"^\d+ results?$"#, options: .regularExpression) != nil }
    }

    /// The caption for exactly the number of entries the index returns for
    /// `query`, which ties the drawn list to this query.
    private func showsResultCount(for query: String, in text: [String]) -> Bool {
        let count = SettingsSearchIndex.matches(query).count
        return text.contains("\(count) result\(count == 1 ? "" : "s")")
    }

    private func showsNoMatches(in text: [String]) -> Bool {
        showsRow(noMatchesTitle, in: text)
    }

    func testPauseMediaQueriesRenderTheDictationToggleRow() throws {
        let mounted = try mountSettings()
        let title = "Pause media while dictating"

        for query in ["pause", "media", "music"] {
            let text = try renderedText(afterTyping: query, into: mounted) { text in
                self.showsRow(title, in: text) && self.showsResultCount(for: query, in: text)
            }
            XCTAssertTrue(
                showsResultCount(for: query, in: text),
                "'\(query)' did not draw its results list. Drawn: \(text)"
            )
            XCTAssertTrue(showsRow(title, in: text), "'\(query)' did not draw the '\(title)' row. Drawn: \(text)")
            XCTAssertFalse(showsNoMatches(in: text), "'\(query)' drew the empty state. Drawn: \(text)")
        }
    }

    func testPushToTalkQueryRendersItsRow() throws {
        let mounted = try mountSettings()
        let title = "Push to talk"

        let query = "push to talk"

        let text = try renderedText(afterTyping: query, into: mounted) { text in
            self.showsRow(title, in: text) && self.showsResultCount(for: query, in: text)
        }

        XCTAssertTrue(
            showsResultCount(for: query, in: text),
            "'\(query)' did not draw its results list. Drawn: \(text)"
        )
        XCTAssertTrue(showsRow(title, in: text), "'\(query)' did not draw the '\(title)' row. Drawn: \(text)")
        XCTAssertFalse(showsNoMatches(in: text), "'\(query)' drew the empty state. Drawn: \(text)")
    }

    func testNonsenseQueryRendersOnlyTheNoMatchesState() throws {
        let mounted = try mountSettings()

        let text = try renderedText(afterTyping: "zzqxv", into: mounted) { text in
            self.showsNoMatches(in: text)
        }

        XCTAssertTrue(showsNoMatches(in: text), "nonsense query did not draw the empty state. Drawn: \(text)")
        XCTAssertFalse(showsAnyResultCount(in: text), "nonsense query drew a result list. Drawn: \(text)")
    }
}
