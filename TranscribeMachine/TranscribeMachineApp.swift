import SwiftUI
import AppKit

private func pinWindowWidth() {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow else { return }
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
        }
    }
}
