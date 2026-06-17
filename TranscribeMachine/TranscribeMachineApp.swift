import SwiftUI

@main
struct TranscribeMachineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, maxWidth: 460, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
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
