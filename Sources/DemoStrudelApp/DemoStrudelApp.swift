import SwiftUI

@main
struct DemoStrudelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) { }  // disable Cmd+N (single-window demo)
        }
    }
}
