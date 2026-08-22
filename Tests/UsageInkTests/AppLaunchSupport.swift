import AppKit
import XCTest
@testable import UsageInk

@MainActor
enum AppLaunchSupport {
    @discardableResult
    static func bootstrapShell() throws -> AppDelegate {
        if PersistenceLocation.overrideRoot == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("usageink-shell-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            PersistenceLocation.overrideRoot = url
        }
        if let existing = AppDelegate.shared {
            if existing.statusItemController == nil {
                existing.applicationDidFinishLaunching(
                    Notification(name: NSApplication.didFinishLaunchingNotification)
                )
            }
            _ = try XCTUnwrap(existing.statusItemController)
            return existing
        }

        let delegate = AppDelegate()
        NSApp.delegate = delegate
        _ = NSApp.setActivationPolicy(.accessory)
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        _ = try XCTUnwrap(delegate.statusItemController)
        return delegate
    }
}
