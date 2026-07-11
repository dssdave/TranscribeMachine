import SwiftUI
import AppKit

// AppDelegate intercepts window close -> hide so the window can always be re-opened
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Assign self as delegate to all current windows, and observe new ones
        for win in NSApp.windows {
            win.delegate = self
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowCreated(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func windowCreated(_ note: Notification) {
        if let win = note.object as? NSWindow, !(win is NSPanel) {
            win.delegate = self
        }
    }

    // Instead of closing, hide the window so makeKeyAndOrderFront can bring it back
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click re-opens hidden window
        if !flag {
            for win in NSApp.windows where !(win is NSPanel) {
                win.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

private func pinWindowWidth() {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        window.minSize = NSSize(width: 420, height: 440)
        window.maxSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        if window.frame.width != 420 {
            var f = window.frame
            f.origin.x += (f.width - 420) / 2
            f.size.width = 420
            window.setFrame(f, display: true, animate: false)
        }
    }
}

@main
struct TranscribeMachineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 420, minHeight: 440)
                .onAppear { pinWindowWidth() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About TranscribeMachine") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    ])
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("TranscribeMachine") {
                    // Window is hidden (not closed) so this always works
                    if let win = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                        win.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
