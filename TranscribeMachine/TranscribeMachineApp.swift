import SwiftUI

@main
struct TranscribeMachineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 420, minHeight: 440)
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
